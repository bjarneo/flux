#pragma once

#include <QObject>
#include <QString>
#include <QTimer>

#include <sys/types.h>

// SelfWatch notices when an update replaces the flux-gui binary on disk.
// The open window then runs the earlier version, so it offers a restart.
class SelfWatch : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool replaced READ replaced NOTIFY replacedChanged)

public:
    explicit SelfWatch(QObject *parent = nullptr);

    bool replaced() const { return m_replaced; }
    // check compares the file on disk with the running binary.
    Q_INVOKABLE void check();
    // restart starts the new binary and quits this one.
    Q_INVOKABLE void restart();

signals:
    void replacedChanged();
    // aboutToRestart asks the owner to release the single-instance socket
    // and lock, so that the new process opens the window. It comes after
    // the new process started.
    void aboutToRestart();

private:
    QString m_path;
    dev_t m_dev = 0;
    ino_t m_ino = 0;
    bool m_replaced = false;
    QTimer m_timer;
};
