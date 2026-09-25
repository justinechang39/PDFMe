# Security

Please do not put sensitive documents, passwords, or exploit details in public issues. Use GitHub’s **Report a vulnerability** feature in the repository Security tab for private reports.

PDFMe invokes the locally installed LibreOffice with the current user’s permissions. Keep LibreOffice and macOS updated. Macro execution and automatic external-link updates are disabled in the isolated conversion profile, but this is not an OS sandbox and does not make arbitrary documents trustworthy.

Passwords are held in memory for one batch and applied with PDFKit; they are not saved to preferences or passed to subprocesses. Temporary plaintext documents exist during conversion in a user-private directory. Normal cleanup removes them, but deletion is not secure erasure and crashes can prevent cleanup.

Supported security fixes target the latest release. The initial public builds are ad-hoc signed and are not notarized by Apple.

Printing passes a prepared PDF to the selected macOS printer queue only after the explicit Print action. Printer destinations and templates stay local; printer configuration is never modified. Preview alone never submits a job. The system spooler and selected printer may retain copies according to their own configuration. Print files and previews are held in private temporary directories, with the same crash-cleanup limitations as conversion.
