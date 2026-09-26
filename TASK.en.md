# Task: restore a production service

You have root SSH access to a disposable Ubuntu server. It runs an existing API service with PostgreSQL, Nginx and systemd that stopped working after a failed update.

Diagnose the state of the server and fully restore the service without losing existing data. Once fixed, it must start automatically after a reboot, run safely on the internet and have a verified database backup.

Audit the configuration as needed, fix the problems you find and verify the result yourself. Do not rewrite the application unless necessary. Leave `/root/REPORT.md` on the server describing the root cause, the changes made, the checks performed and the backup restore procedure.

Do not ask clarifying questions. Choose the technical solutions yourself. This is a fully disposable test server; any changes within it are allowed.
