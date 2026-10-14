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

#ifndef ULTRAHDJOB_H
#define ULTRAHDJOB_H

#include "abstractjob.h"

// Runs the Cap Flash "Ultra HD" AI upscaling script (Real-ESRGAN) on an
// already exported file and writes the final file without metadata.
class UltraHdJob : public AbstractJob
{
    Q_OBJECT
public:
    UltraHdJob(const QString &input,
               const QString &output,
               int targetLongSide,
               const QString &model,
               bool deleteInput = true);
    virtual ~UltraHdJob();
    void start() override;

private slots:
    void onOpenTriggered();
    void onReadyRead() override;
    void onFinished(int exitCode, QProcess::ExitStatus exitStatus) override;

private:
    QString m_input;
    QString m_output;
    int m_targetLongSide;
    QString m_model;
    bool m_deleteInput;
    int m_previousPercent;
};

#endif // ULTRAHDJOB_H
