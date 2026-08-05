' Windowless launcher for the DriveSync scheduled tasks.
'
' Why: "pwsh -WindowStyle Hidden" still flashes a console window briefly,
' because Windows creates the console before PowerShell processes the flag.
' wscript.exe is a GUI-subsystem process, so starting pwsh from here with
' window style 0 shows no window at all.
'
' Usage: wscript.exe //B //Nologo run-hidden.vbs <exe> [args...]
' Every argument is re-quoted, so paths with spaces are safe.
Option Explicit
Dim i, cmd
cmd = ""
For i = 0 To WScript.Arguments.Count - 1
    cmd = cmd & """" & WScript.Arguments.Item(i) & """ "
Next
If cmd <> "" Then
    CreateObject("WScript.Shell").Run Trim(cmd), 0, False
End If
