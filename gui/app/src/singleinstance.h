#pragma once

#include <QLocalServer>
#include <QObject>

// SingleInstance keeps 1 Flux window per session. The first flux-gui takes
// a lock on gui.lock in the folder of the Flux sockets and listens on
// gui.sock in the same folder. A second flux-gui sends its page and its
// activation token there, and then exits. Only the holder of the lock
// listens, so 2 instances that start at the same time cannot both open a
// window.
class SingleInstance : public QObject {
    Q_OBJECT

public:
    explicit SingleInstance(QObject *parent = nullptr);
    ~SingleInstance() override;

    // claim makes this process the single instance. It returns false when
    // a running instance took the request, and the caller then exits. With
    // replace, it does not forward the request. It waits until the running
    // instance releases the lock, for example after a restart.
    bool claim(const QString &page, bool replace);
    // close stops the server and releases the lock, so that a new instance
    // takes over.
    void close();

    static QString socketPath();

signals:
    // activate asks the window to select page and to come to the front.
    // token is the XDG activation token of the second instance, or empty.
    void activate(const QString &page, const QString &token);

private:
    // forward sends the request to a running instance. It returns true
    // when a running instance took it.
    bool forward(const QString &page);
    // openLock opens the lock file in a folder that only this user can use.
    bool openLock();

    QLocalServer m_server;
    int m_lock = -1;
};
