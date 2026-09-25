#pragma once

#include <QLocalServer>
#include <QObject>

// SingleInstance keeps 1 Flux window per session. The first flux-gui
// listens on $XDG_RUNTIME_DIR/flux/gui.sock. A second flux-gui sends its
// page and its activation token there, and then exits.
class SingleInstance : public QObject {
    Q_OBJECT

public:
    explicit SingleInstance(QObject *parent = nullptr);

    // forward sends the request to a running instance. It returns true
    // when a running instance took it.
    bool forward(const QString &page);
    // listen starts the server for later instances.
    bool listen();

    static QString socketPath();

signals:
    // activate asks the window to select page and to come to the front.
    // token is the XDG activation token of the second instance, or empty.
    void activate(const QString &page, const QString &token);

private:
    QLocalServer m_server;
};
