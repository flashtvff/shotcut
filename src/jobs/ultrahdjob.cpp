/*
 * Copyright (c) 2026 Cap Flash contributors
 * Based on Shotcut, Copyright (c) Meltytech, LLC
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "ultrahdjob.h"

#include "Logger.h"
#include "dialogs/textviewerdialog.h"
#include "mainwindow.h"
#include "util.h"

#include <QAction>
#include <QApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QTimer>

UltraHdJob::UltraHdJob(const QString &input,
                       const QString &output,
                       int targetLongSide,
                       const QString &model,
                       bool deleteInput)
    : AbstractJob(output)
    , m_input(input)
    , m_output(output)
    , m_targetLongSide(targetLongSide)
    , m_model(model)
    , m_deleteInput(deleteInput)
    , m_previousPercent(-1)
{
    QAction *action = new QAction(tr("Open"), this);
    action->setData("Open");
    connect(action, &QAction::triggered, this, &UltraHdJob::onOpenTriggered);
    m_successActions << action;

    action = new QAction(tr("Show In Folder"), this);
    connect(action, &QAction::triggered, this, [this]() { Util::showInFolder(m_output); });
    m_successActions << action;

    action = new QAction(tr("View Log"), this);
    connect(action, &QAction::triggered, this, [this]() {
        TextViewerDialog dialog(&MAIN);
        dialog.setWindowTitle(tr("Ultra HD Log"));
        dialog.setText(log());
        dialog.exec();
    });
    m_standardActions << action;

    setLabel(tr("Ultra HD (IA) %1").arg(Util::baseName(output)));
}

UltraHdJob::~UltraHdJob() {}

void UltraHdJob::start()
{
    QDir appDir(qApp->applicationDirPath());
    const QString script = appDir.absoluteFilePath("capflash/ultrahd.ps1");
    if (!QFileInfo::exists(script) || !QFileInfo::exists(m_input)) {
        appendToLog(QStringLiteral("Ultra HD: arquivo ausente: %1 ou %2\n").arg(script, m_input));
        AbstractJob::start();
        // Report asynchronously: JobQueue::startNextJob() holds its mutex while calling start().
        QTimer::singleShot(0, this, [this]() { emit finished(this, false); });
        return;
    }
    QStringList args;
    args << "-NoProfile" << "-ExecutionPolicy" << "Bypass" << "-File"
         << QDir::toNativeSeparators(script) << "-InputFile" << QDir::toNativeSeparators(m_input)
         << "-OutputFile" << QDir::toNativeSeparators(m_output) << "-LongSide"
         << QString::number(m_targetLongSide) << "-Model" << m_model << "-AppDir"
         << QDir::toNativeSeparators(appDir.absolutePath());
    setProcessChannelMode(QProcess::MergedChannels);
    LOG_DEBUG() << "powershell" << args.join(' ');
    AbstractJob::start("powershell.exe", args);
}

void UltraHdJob::onOpenTriggered()
{
    MAIN.open(m_output.toUtf8().constData());
}

void UltraHdJob::onReadyRead()
{
    QString msg;
    do {
        msg = QString::fromUtf8(readLine());
        if (msg.isEmpty())
            break;
        if (msg.startsWith("PROGRESS ")) {
            bool ok = false;
            int percent = msg.mid(9).trimmed().toInt(&ok);
            if (ok && percent != m_previousPercent) {
                emit progressUpdated(m_item, qBound(0, percent, 99));
                m_previousPercent = percent;
            }
        } else {
            appendToLog(msg);
        }
    } while (true);
}

void UltraHdJob::onFinished(int exitCode, QProcess::ExitStatus exitStatus)
{
    const bool ok = exitStatus == QProcess::NormalExit && exitCode == 0 && !stopped();
    if (ok && m_deleteInput && QFileInfo::exists(m_output))
        QFile::remove(m_input);
    AbstractJob::onFinished(exitCode, exitStatus);
}
