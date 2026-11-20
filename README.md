# Fast File Copier and Mover

Fast File Copier and Mover is a graphical user interface (GUI) tool built with PowerShell and embedded C# for high-performance file copying and moving operations. It allows users to select files from multiple sources, review them in a staging area, and efficiently transfer them to a destination.

## Features

- **High-Performance Transfers**: Uses embedded C# with optimized 8MB buffer streams for faster copying compared to standard Windows Explorer.
- **Multi-Source Staging Area**: Gather files and folders from multiple different drives or folders into a single staging queue before initiating the transfer.
- **Auto-Refresh Drives**: Automatically detects when USB drives or network drives are connected/disconnected and refreshes the drive lists.
- **Live Progress & Stats**: Displays real-time transfer speed, overall progress, estimated time of arrival (ETA), and current file status.
- **Pause & Resume**: Easily pause and resume large transfers.
- **Conflict Resolution**: Prompt for actions when a file already exists at the destination (Overwrite, Skip, Keep Both).
- **Safer Replacement**: Writes new file contents to a temporary file and replaces the destination only after the copy completes.
- **Transfer Results**: Reports succeeded, skipped, and failed items, and retains staged move items that still exist at the source.
- **Transfer Preflight**: Shows estimated data size, available destination space, and top-level name conflicts before transfer begins.
- **Responsive Browsing**: Loads directory listings in the background and virtualizes grid rows for large folders.
- **Metadata Preservation**: Best-effort preservation of file timestamps and attributes, plus directory timestamps.
- **Transfer Logs**: Automatically generates a transfer log file in the destination folder after a successful or cancelled operation.
- **Filtering**: Quickly filter source files by name.

## Prerequisites

- **OS**: Windows 10 or Windows 11
- **PowerShell**: Windows PowerShell 5.1
- **.NET Framework**: Uses Windows WPF and Windows Forms components available on supported Windows installations. PowerShell 7 compatibility is not currently verified.

## How to Run

1. Open your File Explorer.
2. Navigate to the folder containing `FastCopier.PS1`.
3. Right-click on `FastCopier.PS1` and select **Run with PowerShell**.
   - *Alternative*: Open a PowerShell console, navigate to the directory, and execute `.\FastCopier.PS1`.

> **Note**: If you receive an "Execution Policy" error, you may need to allow scripts to run on your system. You can bypass this temporarily by opening a PowerShell terminal and running:  
> `powershell.exe -ExecutionPolicy Bypass -File .\FastCopier.PS1`

## Usage Details

### 1. Select Source Directories & Files
- Use the **Active Source Profile** dropdown to select a drive or enter a custom path.
- Browse the folder structure by double-clicking folders or using the **Up Folder** button.
- Check the boxes next to the files or folders you want to transfer.
- Click **+ Add Selected** at the bottom of the left pane to move them to the Staging Area.
- You can also drag and drop files from Windows Explorer directly into the Staging Area.

### 2. Combined Staging Area Review
- The center pane shows all items you have queued for transfer.
- Review the total size of the staged items at the top of the pane.
- To remove items, select them and click **Remove Selected**, or use **Clear All** to empty the queue.

### 3. Choose Destination and Transfer
- In the right pane, select your destination drive and browse to the desired target folder.
- Monitor the **Destination Free Space** bar to ensure you have enough room for the staged files.
- Click **New Folder** if you need to create a subdirectory on the fly.
- Once ready, click **Copy** to copy the files, or **Move** to move them (which deletes the original files after a successful transfer).
- Monitor the progress at the bottom of the window. You can use the **Pause** and **Cancel** buttons if needed.

## Troubleshooting

### "Script cannot be loaded because running scripts is disabled on this system"
PowerShell restricts script execution by default for security.
**Fix**: Run the script with the bypass flag:
```powershell
powershell.exe -ExecutionPolicy Bypass -File .\FastCopier.PS1
```
Or permanently change your execution policy by running PowerShell as Administrator and executing:
```powershell
Set-ExecutionPolicy RemoteSigned
```

### The GUI doesn't load or throws "Add-Type" errors
The script compiles a small block of C# code dynamically. If your system's .NET compiler is restricted (e.g., by aggressive antivirus software or enterprise AppLocker policies), the tool cannot load.
**Fix**: Ensure your antivirus is not blocking PowerShell from compiling C# code (`csc.exe`). 

### Transfer Speed is slower than expected
The tool copies data using 8MB chunks, which is highly efficient. However, transfer speeds are ultimately limited by hardware bottlenecks.
**Fix**: 
- Transferring thousands of very small files (like 1KB each) will always be slower than transferring a single large file due to file system overhead.
- Ensure you are using fast connection ports (USB 3.0+) for external drives.
- Check if your antivirus is aggressively scanning every file read/write during the copy process.

### USB Drive doesn't appear in the dropdown
The script uses WMI to detect new drives automatically. If a drive does not show up:
**Fix**: Click the **Refresh** icon next to the source or destination path dropdowns to force a manual refresh of the drive list.

### Browsing very large folders
Directory listings load in the background and the grids virtualize rows. Very large directories can still take time to enumerate and sort, especially on network shares.

### Destination conflicts or failed transfers
The overwrite prompt offers one-time and all-item choices. A cancelled copy removes its temporary output, and an existing destination file is preserved until its replacement is ready. Check the transfer status and generated transfer log for item-level outcomes. Items that remain at their source stay in the staging queue after a move.

Do not select a destination that is the same as or nested under a staged source folder. The application checks this before starting to prevent recursive copying.

## Limitations
- File timestamps and attributes are preserved on a best-effort basis. Alternate data streams, security descriptors, and hard links are not preserved.
- Preflight size and free-space values are estimates; available space can change before or during transfer. The preflight lists top-level conflicts, while nested conflicts are handled during the transfer.
- Size estimates may be incomplete when Windows denies access to part of a source tree. Check the transfer log for size warnings and per-item results.
- Reparse-point directories are skipped during recursive transfers to avoid traversing directory junction loops.
