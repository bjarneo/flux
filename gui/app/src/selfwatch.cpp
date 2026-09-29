#include "selfwatch.h"

#include <QCoreApplication>
#include <QFile>
#include <QProcess>

#include <sys/stat.h>

namespace {
// checkInterval is the time between 2 checks. A new connection to fluxd
// also starts a check, because fluxd restarts after an update.
constexpr int checkInterval = 30000;
}

SelfWatch::SelfWatch(QObject *parent) : QObject(parent), m_path(QCoreApplication::applicationFilePath())
{
    // /proc/self/exe is the file that runs, also after a new file replaced
    // it on disk.
    struct stat st;
    if (::stat("/proc/self/exe", &st) != 0 || m_path.isEmpty())
        return;
    m_dev = st.st_dev;
    m_ino = st.st_ino;
    m_timer.setInterval(checkInterval);
    connect(&m_timer, &QTimer::timeout, this, &SelfWatch::check);
    m_timer.start();
}

void SelfWatch::check()
{
    if (m_replaced || m_ino == 0)
        return;
    struct stat st;
    if (::stat(QFile::encodeName(m_path).constData(), &st) != 0)
        return;
    if ((st.st_dev == m_dev && st.st_ino == m_ino) || !(st.st_mode & S_IXUSR))
        return;
    m_replaced = true;
    m_timer.stop();
    emit replacedChanged();
}

void SelfWatch::restart()
{
    emit aboutToRestart();
    if (QProcess::startDetached(m_path, {}))
        QCoreApplication::quit();
    else
        qWarning("flux-gui: cannot start %s", qPrintable(m_path));
}
