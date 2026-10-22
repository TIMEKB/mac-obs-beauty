#import "obs-dock-host.h"

#include <obs-frontend-api.h>
#include <QtCore/QCoreApplication>
#include <QtCore/QEvent>
#include <QtCore/QPointer>
#include <QtCore/QTimer>
#include <QtGui/QWindow>
#include <QtGui/QResizeEvent>
#include <QtGui/QShowEvent>
#include <QtWidgets/QApplication>
#include <QtWidgets/QDockWidget>
#include <QtWidgets/QMainWindow>
#include <QtWidgets/QVBoxLayout>
#include <QtWidgets/QWidget>

#include <algorithm>
#include <string>
#include <unordered_map>

#if QT_VERSION_MAJOR != 6
#error This host must use OBS's Qt 6 headers and frameworks, never Qt 5.
#endif

// Retain native content independently of Qt while its native QWidget is
// reparented between the main window and a floating QDockWidget.
@interface LBDockNativeView : NSView
@property(nonatomic, copy) LBDockDeactivateCallback deactivate;
@property(nonatomic, strong) id resignKeyObserver;
@property(nonatomic, strong) id resignApplicationObserver;
@end

@implementation LBDockNativeView
- (BOOL)isFlipped { return YES; }
- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (self.resignKeyObserver) [center removeObserver:self.resignKeyObserver];
    self.resignKeyObserver = nil;
    __weak LBDockNativeView *weakSelf = self;
    if (self.window) {
        self.resignKeyObserver = [center addObserverForName:NSWindowDidResignKeyNotification
            object:self.window queue:nil usingBlock:^(NSNotification *) {
                LBDockNativeView *view = weakSelf;
                if (view.deactivate) view.deactivate();
            }];
    } else if (self.deactivate) {
        self.deactivate();
    }
    if (!self.resignApplicationObserver) {
        self.resignApplicationObserver = [center addObserverForName:NSApplicationDidResignActiveNotification
            object:nil queue:nil usingBlock:^(NSNotification *) {
                LBDockNativeView *view = weakSelf;
                if (view.deactivate) view.deactivate();
            }];
    }
}
- (void)viewDidHide
{
    [super viewDidHide];
    if (self.deactivate) self.deactivate();
}
- (void)dealloc
{
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    if (_resignKeyObserver) [center removeObserver:_resignKeyObserver];
    if (_resignApplicationObserver) [center removeObserver:_resignApplicationObserver];
}
@end

namespace {
struct DockHost;
class DockObserver;
std::unordered_map<std::string, DockHost *> hosts;

bool frontendAvailableOnMain()
{
    if (!qobject_cast<QApplication *>(QCoreApplication::instance())) return false;
    return obs_frontend_get_main_window() != nullptr;
}

class ContentWidget final : public QWidget {
    __strong LBDockNativeView *nativeView;
    bool effectivelyVisible = false;
    bool attaching = false;
public:
    explicit ContentWidget(LBDockNativeView *view) : nativeView(view)
    {
        setAttribute(Qt::WA_NativeWindow);
        setFocusPolicy(Qt::StrongFocus);
        setMinimumSize(300, 240);
        setSizePolicy(QSizePolicy::Expanding, QSizePolicy::Expanding);
        nativeView.hidden = YES;
    }
    ~ContentWidget() override { [nativeView removeFromSuperview]; nativeView = nil; }
    QSize sizeHint() const override { return QSize(460, 680); }
    void attachNative()
    {
        if (attaching || !nativeView || !internalWinId()) return;
        attaching = true;
        NSView *container = (__bridge NSView *)reinterpret_cast<void *>(internalWinId());
        // The native QWidget owns this clipping rectangle. Avoid a foreign
        // QWindow whose independently positioned NSView can overdraw siblings
        // in OBS's existing native video/dock hierarchy.
        container.clipsToBounds = YES;
        nativeView.clipsToBounds = YES;
        if (nativeView.superview != container) {
            [nativeView removeFromSuperview];
            [container addSubview:nativeView];
        }
        nativeView.frame = container.bounds;
        nativeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        nativeView.hidden = !effectivelyVisible;
        attaching = false;
    }
    void setEffectiveVisible(bool value)
    {
        effectivelyVisible = value;
        nativeView.hidden = !value;
        if (value) attachNative();
    }
protected:
    void resizeEvent(QResizeEvent *event) override
    {
        QWidget::resizeEvent(event);
        attachNative();
    }
    void showEvent(QShowEvent *event) override
    {
        QWidget::showEvent(event);
        attachNative();
    }
    bool event(QEvent *event) override
    {
        const auto type = event->type();
        const bool result = QWidget::event(event);
        if (type == QEvent::WinIdChange || type == QEvent::ParentChange)
            attachNative();
        return result;
    }
};

struct DockHost {
    std::string id;
    __strong NSView *content = nil;
    __strong LBDockNativeView *nativeView = nil;
    __strong LBDockVisibilityCallback onVisible = nil;
    __strong LBDockDeactivateCallback onDeactivate = nil;
    QPointer<QWidget> widget;
    QPointer<QWidget> embedded;
    QPointer<QDockWidget> dock;
    DockObserver *observer = nullptr;
    bool registered = false;
    bool disposing = false;
    bool visibleKnown = false;
    bool visible = false;
    bool nativeFocused = false;

    void deactivate()
    {
        if (!disposing && onDeactivate) onDeactivate();
    }
    void visibility(bool value)
    {
        if (disposing) return;
        if (widget) static_cast<ContentWidget *>(widget.data())->setEffectiveVisible(value);
        if (!value) deactivate();
        if (!visibleKnown || visible != value) {
            visibleKnown = true;
            visible = value;
            if (onVisible) onVisible(value);
        }
    }
    bool hasNativeFocus() const
    {
        if (!nativeView.window.isKeyWindow) return false;
        NSResponder *responder = nativeView.window.firstResponder;
        return [responder isKindOfClass:NSView.class] &&
            [(NSView *)responder isDescendantOf:nativeView];
    }
    void pollNativeFocus()
    {
        const bool focused = hasNativeFocus();
        if (nativeFocused && !focused) deactivate();
        nativeFocused = focused;
    }
};

class DockObserver final : public QObject {
    DockHost *host;
    QTimer focusTimer;
public:
    explicit DockObserver(DockHost *value) : host(value)
    {
        // Native WKContentView changes firstResponder without necessarily
        // producing QWidget::FocusOut. This also covers tabbing into Qt UI.
        focusTimer.setInterval(100);
        QObject::connect(&focusTimer, &QTimer::timeout, this, [this] {
            if (!host->disposing) host->pollNativeFocus();
        });
        focusTimer.start();
    }
    bool eventFilter(QObject *object, QEvent *event) override
    {
        if (!host->disposing) {
            switch (event->type()) {
            case QEvent::Hide:
            case QEvent::Close:
            case QEvent::WindowDeactivate:
                host->deactivate();
                break;
            case QEvent::FocusOut:
                if (!host->hasNativeFocus()) host->deactivate();
                break;
            default:
                break;
            }
        }
        return QObject::eventFilter(object, event);
    }
};

QDockWidget *parentDock(QWidget *widget)
{
    for (QWidget *parent = widget ? widget->parentWidget() : nullptr; parent;
         parent = parent->parentWidget()) {
        if (auto *dock = qobject_cast<QDockWidget *>(parent)) return dock;
    }
    return nullptr;
}

void detachAndDeleteWidget(DockHost *host)
{
    // Detach native content before Qt destroys its native QWidget/NSView.
    QPointer<QWidget> widget = host->widget;
    if (host->dock) host->dock->setWidget(nullptr);
    if (widget) delete widget.data();
    [host->content removeFromSuperview];
    [host->nativeView removeFromSuperview];
}
} // namespace

extern "C" bool lb_dock_frontend_available(void)
{
    if (NSThread.isMainThread) return frontendAvailableOnMain();
    __block bool available = false;
    dispatch_sync(dispatch_get_main_queue(), ^{ available = frontendAvailableOnMain(); });
    return available;
}

extern "C" void *lb_dock_create(const char *id, const char *title, NSView *content,
                                 LBDockVisibilityCallback onVisible,
                                 LBDockDeactivateCallback onDeactivate)
{
    if (!id || !*id || !title || !*title || !content) return nullptr;
    const std::string identifier(id), caption(title);
    __block DockHost *result = nullptr;
    void (^create)(void) = ^{
        if (!frontendAvailableOnMain() || hosts.count(identifier)) return;
        auto *host = new DockHost;
        host->id = identifier;
        host->content = content;
        host->onVisible = onVisible;
        host->onDeactivate = onDeactivate;
        NSRect frame = content.bounds;
        frame.origin = NSZeroPoint;
        frame.size.width = std::max<CGFloat>(1, frame.size.width);
        frame.size.height = std::max<CGFloat>(1, frame.size.height);
        host->nativeView = [[LBDockNativeView alloc] initWithFrame:frame];
        content.frame = host->nativeView.bounds;
        content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [host->nativeView addSubview:content];
        host->widget = new ContentWidget(host->nativeView);
        host->embedded = host->widget;
        host->widget->setObjectName(QString::fromUtf8(id) + QStringLiteral("_native_content"));
        if (!obs_frontend_add_dock_by_id(identifier.c_str(), caption.c_str(), host->widget.data())) {
            detachAndDeleteWidget(host);
            delete host;
            return;
        }
        host->registered = true;
        host->dock = parentDock(host->widget);
        if (!host->dock) {
            detachAndDeleteWidget(host);
            obs_frontend_remove_dock(identifier.c_str());
            delete host;
            return;
        }
        hosts.emplace(identifier, host);
        host->observer = new DockObserver(host);
        host->widget->installEventFilter(host->observer);
        host->dock->installEventFilter(host->observer);
        QObject::connect(host->dock, &QDockWidget::visibilityChanged, host->observer,
            [host](bool visible) { host->visibility(visible); });
        QObject::connect(host->dock, &QDockWidget::topLevelChanged, host->observer,
            [host](bool) { host->deactivate(); });
        QObject::connect(host->dock, &QObject::destroyed, host->observer, [host] {
            host->registered = false;
            host->visibility(false);
        });
        host->nativeView.deactivate = ^{ host->deactivate(); };
        // module_post_load precedes OBS 32.2.1's saved DockState restoration.
        // These are initial defaults only; show() never changes docking state.
        host->dock->setFloating(false);
        // Do not show: OBS restores its own hidden/visible state afterward.
        result = host;
        host->visibility(host->dock->isVisible());
    };
    if (NSThread.isMainThread) create();
    else dispatch_sync(dispatch_get_main_queue(), create);
    return result;
}

extern "C" void lb_dock_show(void *opaque)
{
    auto *host = static_cast<DockHost *>(opaque);
    if (!host) return;
    void (^show)(void) = ^{
        if (host->disposing || !host->registered || !host->dock) return;
        host->dock->show();
        host->dock->raise();
        host->dock->activateWindow();
        if (host->embedded) host->embedded->setFocus(Qt::OtherFocusReason);
        NSWindow *window = host->nativeView.window;
        if (window) [window makeFirstResponder:host->content];
        host->pollNativeFocus();
    };
    if (NSThread.isMainThread) show();
    else dispatch_sync(dispatch_get_main_queue(), show);
}

extern "C" bool lb_dock_is_visible(void *opaque)
{
    auto *host = static_cast<DockHost *>(opaque);
    if (!host) return false;
    __block bool visible = false;
    void (^read)(void) = ^{
        // A tabified dock's QWidget can remain isVisible()==true while another
        // tab covers it. Match QDockWidget::visibilityChanged, as callbacks do.
        visible = !host->disposing && host->dock &&
            (host->visibleKnown ? host->visible : host->dock->isVisible());
    };
    if (NSThread.isMainThread) read();
    else dispatch_sync(dispatch_get_main_queue(), read);
    return visible;
}

extern "C" void lb_dock_destroy(void *opaque)
{
    auto *host = static_cast<DockHost *>(opaque);
    if (!host) return;
    void (^destroy)(void) = ^{
        if (host->onDeactivate) host->onDeactivate();
        host->disposing = true;
        host->nativeView.deactivate = nil;
        delete host->observer;
        host->observer = nullptr;
        const bool registered = host->registered;
        detachAndDeleteWidget(host);
        if (registered && frontendAvailableOnMain()) obs_frontend_remove_dock(host->id.c_str());
        hosts.erase(host->id);
        host->onVisible = nil;
        host->onDeactivate = nil;
        delete host;
    };
    if (NSThread.isMainThread) destroy();
    else dispatch_sync(dispatch_get_main_queue(), destroy);
}

extern "C" void lb_dock_group_in_main_window(void)
{
    void (^group)(void) = ^{
        if (!frontendAvailableOnMain()) return;
        auto *mainWindow = qobject_cast<QMainWindow *>(static_cast<QWidget *>(obs_frontend_get_main_window()));
        if (!mainWindow) return;
        QDockWidget *anchor = nullptr;
        QDockWidget *preferred = nullptr;
        for (const char *id : {"live-beauty-dock"}) {
            auto *dock = mainWindow->findChild<QDockWidget *>(QString::fromUtf8(id));
            if (!dock) continue;
            dock->setFloating(false);
            mainWindow->addDockWidget(Qt::RightDockWidgetArea, dock);
            if (anchor) mainWindow->tabifyDockWidget(anchor, dock);
            else anchor = dock;
            dock->show();
        }
        preferred = mainWindow->findChild<QDockWidget *>(QStringLiteral("live-beauty-dock"));
        if (!preferred) preferred = anchor;
        if (preferred) {
            preferred->raise();
            mainWindow->raise();
            mainWindow->activateWindow();
        }
    };
    if (NSThread.isMainThread) group();
    else dispatch_sync(dispatch_get_main_queue(), group);
}
