// flux-gui is the Qt6 window of Flux. It shows the same QML views as the
// Omarchy shell plugin and talks to fluxd over its IPC socket.

#include <QCommandLineParser>
#include <QDir>
#include <QGuiApplication>
#include <QProcess>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QTimer>
#include <QUrl>

#include <vector>

#include "fluxbackend.h"
#include "singleinstance.h"
#include "themewatcher.h"

namespace {

// qmlBase returns the folder of the shared views: the resources, or
// FLUX_QML_DIR for development.
QString qmlBase()
{
    const QString dir = qEnvironmentVariable("FLUX_QML_DIR");
    if (!dir.isEmpty())
        return QUrl::fromLocalFile(QDir(dir).absolutePath()).toString();
    return QStringLiteral("qrc:/flux/qml");
}

FluxBackend *expose(QQmlApplicationEngine &engine)
{
    auto *backend = new FluxBackend(&engine, &engine);
    QQmlContext *ctx = engine.rootContext();
    ctx->setContextProperty(QStringLiteral("fluxQmlBase"), qmlBase());
    ctx->setContextProperty(QStringLiteral("fluxTheme"), new ThemeWatcher(&engine));
    ctx->setContextProperty(QStringLiteral("fluxBackend"), backend);
    return backend;
}

// raise brings the window to the front. Wayland lets a window take focus
// only with an activation token. Without a token, flux-gui asks Hyprland.
void raise(QQuickWindow *window, const QString &token)
{
    window->show();
    window->raise();
    if (!token.isEmpty()) {
        qputenv("XDG_ACTIVATION_TOKEN", token.toUtf8());
        window->requestActivate();
        return;
    }
    QProcess::startDetached(QStringLiteral("hyprctl"),
                            {QStringLiteral("dispatch"), QStringLiteral("focuswindow"), QStringLiteral("class:^flux$")});
}

// snapshot renders every screen of the shared views with the mock backend
// into PNG files. Snapshot.qml reads the arguments after "--", so argv is
// rebuilt as "flux-gui -- DIR [ONLY]" before Qt reads it.
int snapshot(int argc, char *argv[])
{
    std::vector<char *> args{argv[0], const_cast<char *>("--")};
    for (int i = 1; i < argc; i++) {
        if (qstrcmp(argv[i], "--snapshot") != 0)
            args.push_back(argv[i]);
    }
    int count = int(args.size());
    args.push_back(nullptr);

    QGuiApplication::setDesktopFileName(QStringLiteral("flux"));
    QGuiApplication app(count, args.data());
    // The harness reads its fixture and the environment with XMLHttpRequest.
    qputenv("QML_XHR_ALLOW_FILE_READ", "1");
    QQmlApplicationEngine engine;
    engine.load(QUrl(qmlBase() + QStringLiteral("/tools/Snapshot.qml")));
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}

// grabAfterState saves the window into a PNG file after the first state
// from fluxd, and then quits. It proves the whole path from fluxd to the
// pixels. Set FLUX_GUI_GRAB=<file.png> to use it.
void grabAfterState(QQuickWindow *window, FluxBackend *backend, const QString &file)
{
    auto save = [window, backend, file] {
        const int devices = backend->devices().property(QStringLiteral("length")).toInt();
        qInfo("flux-gui: connected=%d devices=%d", backend->connected(), devices);
        const bool ok = window->grabWindow().save(file);
        qInfo("flux-gui: %s %s", ok ? "saved" : "cannot save", qPrintable(file));
        QCoreApplication::exit(ok ? 0 : 1);
    };
    QObject::connect(backend, &FluxBackend::stateChanged, window, [save] { QTimer::singleShot(1500, save); },
                     Qt::SingleShotConnection);
    QTimer::singleShot(8000, window, save);
}

} // namespace

int main(int argc, char *argv[])
{
    for (int i = 1; i < argc; i++) {
        if (qstrcmp(argv[i], "--snapshot") == 0)
            return snapshot(argc, argv);
    }

    QGuiApplication::setDesktopFileName(QStringLiteral("flux"));
    QGuiApplication app(argc, argv);
    QGuiApplication::setApplicationName(QStringLiteral("flux"));
    QGuiApplication::setApplicationVersion(QStringLiteral(FLUX_VERSION));

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("The Flux window. It connects to fluxd."));
    parser.addHelpOption();
    parser.addVersionOption();
    // --snapshot is handled before the parser runs. It is listed for --help.
    parser.addOption({QStringLiteral("snapshot"),
                      QStringLiteral("Render every screen with test data into PNG files in <dir>, then quit."),
                      QStringLiteral("dir")});
    parser.addPositionalArgument(QStringLiteral("page"),
                                 QStringLiteral("The page to open: overview, clipboard, files, notifications, media, "
                                                "messages, commands, or browse. With --snapshot: the screens to render."),
                                 QStringLiteral("[page]"));
    parser.process(app);
    const QString page = parser.positionalArguments().value(0);

    SingleInstance instance;
    if (instance.forward(page))
        return 0;
    if (!instance.listen())
        qWarning("flux-gui: cannot listen on %s", qPrintable(SingleInstance::socketPath()));

    QQmlApplicationEngine engine;
    FluxBackend *backend = expose(engine);
    engine.rootContext()->setContextProperty(QStringLiteral("fluxInitialPage"), page);
    engine.load(QUrl(QStringLiteral("qrc:/flux/app/Main.qml")));
    if (engine.rootObjects().isEmpty())
        return 1;
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (!window)
        return 1;

    QObject::connect(&instance, &SingleInstance::activate, window, [window](const QString &page, const QString &token) {
        if (!page.isEmpty())
            QMetaObject::invokeMethod(window, "showPage", Q_ARG(QVariant, page));
        raise(window, token);
    });
    if (const QString grab = qEnvironmentVariable("FLUX_GUI_GRAB"); !grab.isEmpty())
        grabAfterState(window, backend, grab);
    return app.exec();
}
