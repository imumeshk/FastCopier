<#
.SYNOPSIS
Fast File Copier and Mover GUI Tool
.VERSION
1.1.0
.DESCRIPTION
Supports Multi-Drive Source Selections and Auto-Refresh Network/USB Drives
#>

$script:FastCopierVersion = '1.1.0'

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Management
Add-Type -AssemblyName Microsoft.VisualBasic

# CSharp Helper
$CSharpCode = @"
using System;
using System.IO;
using System.Threading;
using System.Windows.Threading;
using System.ComponentModel;
using System.Collections.Generic;
using System.Linq;

public class FileItem : INotifyPropertyChanged
{
    private bool _isSelected;
    public bool IsSelected 
    { 
        get { return _isSelected; } 
        set { 
            if (_isSelected != value) {
                _isSelected = value; 
                OnPropertyChanged("IsSelected"); 
            }
        } 
    }
    
    public string Type { get; set; }
    public string Name { get; set; }
    public string FullPath { get; set; }
    public long Size { get; set; }
    public string SizeStr { get; set; }
    public string SourceDisplay { get; set; }
    public string Status { get; set; }
    public string Icon { get; set; }
    public string IconColor { get; set; }
    public string CreationTime { get; set; }
    
    public event PropertyChangedEventHandler PropertyChanged;
    protected void OnPropertyChanged(string name)
    {
        if (PropertyChanged != null)
        {
            PropertyChanged(this, new PropertyChangedEventArgs(name));
        }
    }
}

public static class DirectoryLoader
{
    public static void LoadAsync(string path, bool showHidden, Dispatcher dispatcher, Action<List<FileItem>, string> callback)
    {
        ThreadPool.QueueUserWorkItem(_ =>
        {
            List<FileItem> items = new List<FileItem>();
            string error = null;
            try
            {
                foreach (string entryPath in Directory.EnumerateFileSystemEntries(path))
                {
                    try
                    {
                        FileAttributes attributes = File.GetAttributes(entryPath);
                        if (!showHidden && (attributes & FileAttributes.Hidden) == FileAttributes.Hidden) continue;
                        bool isDirectory = (attributes & FileAttributes.Directory) == FileAttributes.Directory;
                        FileInfo fi = isDirectory ? null : new FileInfo(entryPath);
                        string ext = isDirectory ? "" : Path.GetExtension(entryPath);
                        items.Add(new FileItem {
                            Name = Path.GetFileName(entryPath), FullPath = entryPath,
                            Type = isDirectory ? "Folder" : (String.IsNullOrWhiteSpace(ext) ? "File" : ext),
                            Size = isDirectory ? 0 : fi.Length,
                            SizeStr = isDirectory ? "" : FormatSize(fi.Length),
                            CreationTime = (isDirectory ? Directory.GetCreationTime(entryPath) : fi.CreationTime).ToString("yyyy-MM-dd HH:mm"),
                            Icon = isDirectory ? Char.ConvertFromUtf32(0xE8B7) : Char.ConvertFromUtf32(0xE7C3),
                            IconColor = isDirectory ? "#F59E0B" : "#64748B",
                            Status = "Ready"
                        });
                    }
                    catch (Exception ex) { error = "Some entries could not be read: " + ex.Message; }
                }
                items.Sort((a, b) => {
                    bool ad = a.Type == "Folder", bd = b.Type == "Folder";
                    if (ad != bd) return ad ? -1 : 1;
                    return String.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase);
                });
            }
            catch (Exception ex) { error = ex.Message; }
            if (dispatcher != null && callback != null) {
                try { dispatcher.BeginInvoke(new Action(() => callback(items, error))); }
                catch { /* The window may close while a directory listing is finishing. */ }
            }
        });
    }

    private static string FormatSize(long bytes)
    {
        if (bytes >= 1024L * 1024L * 1024L) return String.Format("{0:N2} GB", (double)bytes / (1024L * 1024L * 1024L));
        if (bytes >= 1024L * 1024L) return String.Format("{0:N2} MB", (double)bytes / (1024L * 1024L));
        if (bytes >= 1024L) return String.Format("{0:N2} KB", (double)bytes / 1024L);
        return bytes + " B";
    }
}

public class FastFileMover
{
    private const int BufferSize = 8 * 1024 * 1024;

    public Dispatcher UIDispatcher { get; set; }
    public Action<long, long, string> UIProgressAction { get; set; }
    public Func<string, int> UIOverwritePrompt { get; set; }
    public Func<long, bool> UIPreflightAction { get; set; }

    public int DefaultOverwriteAction = -1; 
    public long TotalBytes = 0;
    public long ProcessedBytes = 0;
    public bool IsCancelled = false;
    public int SuccessCount = 0;
    public int SkippedCount = 0;
    public int FailedCount = 0;

    public ManualResetEvent PauseEvent = new ManualResetEvent(true);

    public List<string> TransferLog = new List<string>();
    private object logLock = new object();

    public void Log(string message) {
        lock (logLock) {
            TransferLog.Add(DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message);
        }
    }

    private long lastTick = 0;

    private void ReportProgress(string file)
    {
        long currentTicks = DateTime.Now.Ticks;
        // Throttle updates to ~60fps (16ms)
        if (currentTicks - lastTick > 160000)
        {
            lastTick = currentTicks;
            if (UIDispatcher != null && UIProgressAction != null)
            {
                UIDispatcher.Invoke(new Action(() => {
                    UIProgressAction(ProcessedBytes, TotalBytes, file);
                }));
            }
        }
    }

    private void ForceReportProgress(string file)
    {
        if (UIDispatcher != null && UIProgressAction != null)
        {
            UIDispatcher.Invoke(new Action(() => {
                UIProgressAction(ProcessedBytes, TotalBytes, file);
            }));
        }
    }

    private int PromptOverwrite(string file)
    {
        if (UIDispatcher != null && UIOverwritePrompt != null)
        {
            object res = UIDispatcher.Invoke(UIOverwritePrompt, new object[] { file });
            return Convert.ToInt32(res);
        }
        return 0;
    }

    private bool IsOccupied(string path) { return File.Exists(path) || Directory.Exists(path); }

    private string ResolveConflict(string source, ref string dest)
    {
        if (!IsOccupied(dest)) return "write";
        int action = DefaultOverwriteAction == -1 ? PromptOverwrite(dest) : DefaultOverwriteAction;
        if (action == 3) { IsCancelled = true; Log("[CANCELLED] " + source); return "cancel"; }
        if (action == 0 || action == 4) {
            if (action == 4) DefaultOverwriteAction = 0;
            SkippedCount++; Log("[SKIPPED] " + source); return "skip";
        }
        if (action == 2) { DefaultOverwriteAction = 2; action = 1; }
        if (action == 6) { DefaultOverwriteAction = 6; action = 5; }
        if (action == 5) {
            string dir = Path.GetDirectoryName(dest), name = Path.GetFileNameWithoutExtension(dest), ext = Path.GetExtension(dest);
            int counter = 1;
            do { dest = Path.Combine(dir ?? "", string.Format("{0} ({1}){2}", name, counter++, ext)); } while (IsOccupied(dest));
            return "write";
        }
        if (action == 1) return "replace";
        SkippedCount++; Log("[SKIPPED] " + source); return "skip";
    }

    public bool CopyFileFast(string source, string dest)
    {
        if (IsCancelled) return false;
        string conflict = ResolveConflict(source, ref dest);
        if (conflict != "write" && conflict != "replace") return false;
        string temp = null;
        try {
            FileInfo sourceInfo = new FileInfo(source);
            DateTime creationTimeUtc = sourceInfo.CreationTimeUtc;
            DateTime lastWriteTimeUtc = sourceInfo.LastWriteTimeUtc;
            DateTime lastAccessTimeUtc = sourceInfo.LastAccessTimeUtc;
            FileAttributes sourceAttributes = File.GetAttributes(source) & ~FileAttributes.ReparsePoint;
            string destDirectory = Path.GetDirectoryName(dest);
            if (!string.IsNullOrEmpty(destDirectory) && !Directory.Exists(destDirectory)) Directory.CreateDirectory(destDirectory);
            temp = Path.Combine(destDirectory ?? ".", ".fastcopier-" + Guid.NewGuid().ToString("N") + ".tmp");
            using (var sourceStream = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read, BufferSize, FileOptions.SequentialScan))
            using (var destStream = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None, BufferSize, FileOptions.SequentialScan))
            {
                byte[] buffer = new byte[BufferSize];
                int bytesRead;
                while ((bytesRead = sourceStream.Read(buffer, 0, buffer.Length)) > 0)
                {
                    PauseEvent.WaitOne();
                    if (IsCancelled) return false;
                    destStream.Write(buffer, 0, bytesRead);
                    Interlocked.Add(ref ProcessedBytes, bytesRead);
                    ReportProgress(source);
                }
            }
            if (IsCancelled) return false;
            try {
                File.SetCreationTimeUtc(temp, creationTimeUtc);
                File.SetLastWriteTimeUtc(temp, lastWriteTimeUtc);
                File.SetLastAccessTimeUtc(temp, lastAccessTimeUtc);
                File.SetAttributes(temp, sourceAttributes);
            } catch (Exception ex) { Log("[METADATA WARNING] " + source + " : " + ex.Message); }
            if (conflict == "replace") {
                if (Directory.Exists(dest)) throw new IOException("A directory occupies the destination path.");
                if (File.Exists(dest)) File.Replace(temp, dest, null); else File.Move(temp, dest);
            } else File.Move(temp, dest);
            temp = null;
            ForceReportProgress(source);
            Log(string.Format("[COPIED] {0} -> {1}", source, dest));
            SuccessCount++;
            return true;
        }
        catch (Exception ex) { FailedCount++; Log(string.Format("[ERROR] {0} : {1}", source, ex.Message)); return false; }
        finally { if (temp != null) try { if (File.Exists(temp)) File.Delete(temp); } catch {} }
    }
    
    public void MoveFileFast(string source, string dest)
    {
        PauseEvent.WaitOne();
        if (IsCancelled) return;
        string conflict = ResolveConflict(source, ref dest);
        if (conflict != "write" && conflict != "replace") return;
        try {
            long length = new FileInfo(source).Length;
            if (conflict == "write") {
              try {
                File.Move(source, dest);
                Interlocked.Add(ref ProcessedBytes, length); SuccessCount++;
                ForceReportProgress(source); Log(string.Format("[MOVED] {0} -> {1}", source, dest)); return;
              } catch (IOException) { /* Cross-volume move; fall through to verified copy. */ }
            }
            int previousOverwriteAction = DefaultOverwriteAction;
            if (conflict == "replace") DefaultOverwriteAction = 1;
            bool copied = CopyFileFast(source, dest);
            DefaultOverwriteAction = previousOverwriteAction;
            if (copied) {
                try { File.Delete(source); Log(string.Format("[MOVED] {0} -> {1}", source, dest)); }
                catch (Exception ex) { FailedCount++; Log(string.Format("[ERROR DELETING SOURCE] {0} : {1}", source, ex.Message)); }
            }
        } catch (Exception ex) { FailedCount++; Log(string.Format("[ERROR] {0} : {1}", source, ex.Message)); }
    }
    
    public long GetTotalSize(string[] paths)
    {
        long size = 0;
        if (paths == null) return 0;
        foreach (var path in paths)
        {
            try {
                if (File.Exists(path)) size += new FileInfo(path).Length;
                else if (Directory.Exists(path)) size += GetDirectorySize(path);
                else Log("[SIZE WARNING] Source does not exist: " + path);
            } catch (Exception ex) { Log("[SIZE WARNING] " + path + " : " + ex.Message); }
        }
        return size;
    }
    
    private long GetDirectorySize(string folderPath)
    {
        long size = 0;
        try {
            if ((File.GetAttributes(folderPath) & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint) {
                Log("[SIZE WARNING] Skipped reparse-point source directory: " + folderPath);
                return 0;
            }
        } catch (Exception ex) { Log("[SIZE WARNING] " + folderPath + " : " + ex.Message); return 0; }
        Stack<string> pending = new Stack<string>();
        pending.Push(folderPath);
        while (pending.Count > 0) {
            string current = pending.Pop();
            try {
                foreach (string file in Directory.EnumerateFiles(current)) {
                    try { size += new FileInfo(file).Length; }
                    catch (Exception ex) { Log("[SIZE WARNING] " + file + " : " + ex.Message); }
                }
                foreach (string dir in Directory.EnumerateDirectories(current)) {
                    try {
                        if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) != FileAttributes.ReparsePoint)
                            pending.Push(dir);
                        else Log("[SIZE WARNING] Skipped reparse-point directory: " + dir);
                    } catch (Exception ex) { Log("[SIZE WARNING] " + dir + " : " + ex.Message); }
                }
            } catch (Exception ex) { Log("[SIZE WARNING] " + current + " : " + ex.Message); }
        }
        return size;
    }

    public void ProcessDirectory(string sourceDir, string destDir, bool move)
    {
        if (IsCancelled) return;
        try
        {
            if ((File.GetAttributes(sourceDir) & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint) {
                SkippedCount++; Log("[SKIPPED] Reparse-point source directory: " + sourceDir); return;
            }
            DateTime sourceCreationUtc = Directory.GetCreationTimeUtc(sourceDir);
            DateTime sourceWriteUtc = Directory.GetLastWriteTimeUtc(sourceDir);
            DateTime sourceAccessUtc = Directory.GetLastAccessTimeUtc(sourceDir);
            if (!Directory.Exists(destDir))
                Directory.CreateDirectory(destDir);
                
            foreach (string file in Directory.EnumerateFiles(sourceDir))
            {
                PauseEvent.WaitOne();
                if (IsCancelled) break;
                string destFile = Path.Combine(destDir, Path.GetFileName(file));
                if (move) MoveFileFast(file, destFile);
                else CopyFileFast(file, destFile);
            }
            
            foreach (string dir in Directory.EnumerateDirectories(sourceDir))
            {
                PauseEvent.WaitOne();
                if (IsCancelled) break;
                if ((File.GetAttributes(dir) & FileAttributes.ReparsePoint) == FileAttributes.ReparsePoint) {
                    Log("[SKIPPED] Reparse-point directory: " + dir);
                    SkippedCount++;
                    continue;
                }
                string destSubDir = Path.Combine(destDir, Path.GetFileName(dir));
                ProcessDirectory(dir, destSubDir, move);
            }
            
            if (move && !IsCancelled)
            {
                try { Directory.Delete(sourceDir, false); }
                catch (Exception ex) { FailedCount++; Log("[DIRECTORY RETAINED] " + sourceDir + " : " + ex.Message); }
            }
            if (!IsCancelled && Directory.Exists(destDir)) {
                try {
                    Directory.SetCreationTimeUtc(destDir, sourceCreationUtc);
                    Directory.SetLastWriteTimeUtc(destDir, sourceWriteUtc);
                    Directory.SetLastAccessTimeUtc(destDir, sourceAccessUtc);
                } catch (Exception ex) { Log("[METADATA WARNING] " + sourceDir + " : " + ex.Message); }
            }
        }
        catch (Exception ex) { FailedCount++; Log("[DIRECTORY ERROR] " + sourceDir + " : " + ex.Message); }
    }

    public void ProcessItems(string[] sources, string destFolder, bool move)
    {
        foreach (var src in sources)
        {
            PauseEvent.WaitOne();
            if (IsCancelled) break;
            string destItem = Path.Combine(destFolder, Path.GetFileName(src));
            if (File.Exists(src))
            {
                if (move) MoveFileFast(src, destItem);
                else CopyFileFast(src, destItem);
            }
            else if (Directory.Exists(src))
            {
                ProcessDirectory(src, destItem, move);
            }
            else { FailedCount++; Log("[MISSING SOURCE] " + src); }
        }
    }

    public void ProcessItems(string[] sources, string[] destinations, bool move)
    {
        if (sources == null || destinations == null) return;

        if (sources.Length != destinations.Length) Log("[WARNING] Source and destination list lengths differ; unmatched items were ignored.");
        int itemCount = Math.Min(sources.Length, destinations.Length);
        for (int i = 0; i < itemCount; i++)
        {
            PauseEvent.WaitOne();
            if (IsCancelled) break;

            string src = sources[i];
            string dest = destinations[i];
            if (string.IsNullOrWhiteSpace(src) || string.IsNullOrWhiteSpace(dest)) continue;

            if (File.Exists(src))
            {
                if (move) MoveFileFast(src, dest);
                else CopyFileFast(src, dest);
            }
            else if (Directory.Exists(src))
            {
                ProcessDirectory(src, dest, move);
            }
            else { FailedCount++; Log("[MISSING SOURCE] " + src); }
        }
    }

    public void CalculateStagedSizeAsync(string[] paths, Action<long> callback)
    {
        ThreadPool.QueueUserWorkItem(_ => {
            long total = GetTotalSize(paths);
            if (UIDispatcher != null && callback != null) {
                UIDispatcher.Invoke(new Action(() => callback(total)));
            }
        });
    }

    public void ProcessItemsAsync(string[] sources, string destFolder, bool move, Action onPreProcess, Action onComplete)
    {
        ThreadPool.QueueUserWorkItem(_ => {
            ProcessedBytes = 0;
            TotalBytes = 0;
            IsCancelled = false;
            SuccessCount = 0;
            SkippedCount = 0;
            FailedCount = 0;
            DefaultOverwriteAction = -1;
            lastTick = 0;
            TransferLog = new List<string>();

            try
            {
                long total = GetTotalSize(sources);
                TotalBytes = total;

                bool proceed = true;
                if (UIDispatcher != null && UIPreflightAction != null)
                    proceed = Convert.ToBoolean(UIDispatcher.Invoke(UIPreflightAction, new object[] { total }));
                if (!proceed) { IsCancelled = true; Log("[CANCELLED] Preflight declined."); return; }

                if (UIDispatcher != null && onPreProcess != null) {
                    UIDispatcher.Invoke(onPreProcess);
                }

                ProcessItems(sources, destFolder, move);
            }
            catch (Exception ex) { FailedCount++; Log("[TRANSFER ERROR] " + ex.Message); }
            finally
            {
                if (UIDispatcher != null && onComplete != null) {
                    UIDispatcher.Invoke(onComplete);
                }
            }
        });
    }

    public void ProcessItemsAsync(string[] sources, string[] destinations, bool move, Action onPreProcess, Action onComplete)
    {
        ThreadPool.QueueUserWorkItem(_ => {
            ProcessedBytes = 0;
            TotalBytes = 0;
            IsCancelled = false;
            SuccessCount = 0;
            SkippedCount = 0;
            FailedCount = 0;
            DefaultOverwriteAction = -1;
            lastTick = 0;
            TransferLog = new List<string>();

            try
            {
                long total = GetTotalSize(sources);
                TotalBytes = total;

                bool proceed = true;
                if (UIDispatcher != null && UIPreflightAction != null)
                    proceed = Convert.ToBoolean(UIDispatcher.Invoke(UIPreflightAction, new object[] { total }));
                if (!proceed) { IsCancelled = true; Log("[CANCELLED] Preflight declined."); return; }

                if (UIDispatcher != null && onPreProcess != null) {
                    UIDispatcher.Invoke(onPreProcess);
                }

                ProcessItems(sources, destinations, move);
            }
            catch (Exception ex) { FailedCount++; Log("[TRANSFER ERROR] " + ex.Message); }
            finally
            {
                if (UIDispatcher != null && onComplete != null) {
                    UIDispatcher.Invoke(onComplete);
                }
            }
        });
    }
}
"@

if (-not ('FileItem' -as [type]) -or -not ('FastFileMover' -as [type])) {
    Add-Type -TypeDefinition $CSharpCode -Language CSharp -ReferencedAssemblies "System", "System.Core", "WindowsBase" -ErrorAction Stop
}

# --- UI Definition ---
[xml]$XAML = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Fast Multi-Source File Copier" Height="750" Width="1200" WindowStartupLocation="CenterScreen" WindowState="Maximized"
        Background="#F4F6F8" FontFamily="Segoe UI" FontSize="14">
    <Window.Resources>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#3A7E99"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="10,4"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" CornerRadius="5" Padding="{TemplateBinding Padding}" BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Opacity" Value="0.85"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Opacity" Value="0.5"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        
        <Style TargetType="Button" x:Key="SecondaryButton">
            <Setter Property="Background" Value="#FFFFFF"/>
            <Setter Property="Foreground" Value="#374151"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="Padding" Value="10,4"/>
            <Setter Property="Margin" Value="4"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" BorderThickness="{TemplateBinding BorderThickness}" BorderBrush="{TemplateBinding BorderBrush}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#F3F4F6"/>
                </Trigger>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Opacity" Value="0.5"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="White"/>
            <Setter Property="RowBackground" Value="White"/>
            <Setter Property="AlternatingRowBackground" Value="#F9FAFB"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#E5E7EB"/>
            <Setter Property="VerticalGridLinesBrush" Value="Transparent"/>
            <Setter Property="RowHeight" Value="30"/>
            <Setter Property="HeadersVisibility" Value="Column"/>
            <Setter Property="CanUserAddRows" Value="False"/>
            <Setter Property="AutoGenerateColumns" Value="False"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="EnableRowVirtualization" Value="True"/>
            <Setter Property="EnableColumnVirtualization" Value="True"/>
            <Setter Property="VirtualizingPanel.VirtualizationMode" Value="Recycling"/>
            <Setter Property="ScrollViewer.IsDeferredScrollingEnabled" Value="True"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#F8FAFC"/>
            <Setter Property="Foreground" Value="#475569"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="BorderThickness" Value="0,0,0,1"/>
            <Setter Property="BorderBrush" Value="#E2E8F0"/>
        </Style>
        
        <Style x:Key="ToolbarButtonStyle" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
            <Setter Property="Height" Value="30"/>
            <Setter Property="Width" Value="34"/>
            <Setter Property="Padding" Value="0"/>
            <Setter Property="Margin" Value="0,0,6,0"/>
            <Setter Property="FontSize" Value="16"/>
            <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
        </Style>
        
        <Style x:Key="ToolbarComboStyle" TargetType="ComboBox">
            <Setter Property="MinHeight" Value="30"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="BorderBrush" Value="#D1D5DB"/>
            <Setter Property="Background" Value="White"/>
        </Style>

        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#E2EAF4"/>
        <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="Black"/>
    </Window.Resources>
    
    <Grid Margin="15">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Top Header Area -->
        <Grid Grid.Row="0" Margin="0,0,0,12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="&#xE8B7;" FontFamily="Segoe MDL2 Assets" FontSize="26" Margin="0,0,12,0" Foreground="#357790"/>
                <TextBlock Text="FAST MULTI-SOURCE FILE COPIER" FontSize="20" FontWeight="Bold" Foreground="#1E293B" VerticalAlignment="Center"/>
            </StackPanel>
            <Button Name="BtnToggleHidden" Grid.Column="1" Content="&#xE890;" Style="{StaticResource ToolbarButtonStyle}" Margin="0" ToolTip="Show Hidden Files: OFF"/>
        </Grid>

        <!-- 3 Columns Content with SharedSizeScope to match all Row heights -->
        <Grid Grid.Row="1" Grid.IsSharedSizeScope="True">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="1*" />
                <ColumnDefinition Width="1.1*" />
                <ColumnDefinition Width="1*" />
            </Grid.ColumnDefinitions>

            <!-- Left Pane: Source Browser -->
            <Grid Grid.Column="0" Margin="0,0,12,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" SharedSizeGroup="HeaderRow"/>
                    <RowDefinition Height="Auto" SharedSizeGroup="ToolbarRow"/>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto" SharedSizeGroup="ActionRow"/>
                </Grid.RowDefinitions>
                
                <TextBlock Grid.Row="0" Text="1. SELECT SOURCE DIRECTORIES &amp; FILES" FontWeight="Bold" FontSize="14" Foreground="#1E293B" VerticalAlignment="Center"/>
                
                <!-- Floating Combo Area -->
                <Grid Grid.Row="1" Margin="0,4,0,8" VerticalAlignment="Bottom">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    
                    <Grid Grid.Column="0" Margin="0,0,8,0">
                        <Border BorderBrush="#B9CDD8" BorderThickness="1" CornerRadius="4" Margin="0,8,0,0" Background="White">
                            <ComboBox Name="SourceDriveCombo" BorderThickness="0" Background="Transparent" Style="{StaticResource ToolbarComboStyle}" IsEditable="True" Height="30"/>
                        </Border>
                        <TextBlock Text=" Active Source Profile " Background="#F4F6F8" Foreground="#4B5563" FontSize="12" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="8,0,0,0"/>
                    </Grid>
                    
                    <Button Name="SourceRefreshButton" Grid.Column="1" VerticalAlignment="Bottom" Content="&#xE72C;" Style="{StaticResource ToolbarButtonStyle}" ToolTip="Refresh"/>
                    <Button Name="SourceUpButton" Grid.Column="2" VerticalAlignment="Bottom" Content="&#xE74A;" Style="{StaticResource ToolbarButtonStyle}" Margin="0" ToolTip="Up Folder"/>
                </Grid>

                <Grid Grid.Row="2" Margin="0,0,0,8">
                    <Border BorderBrush="#B9CDD8" BorderThickness="1" CornerRadius="4" Background="White">
                        <TextBox Name="SourceFilterBox" BorderThickness="0" Background="Transparent" VerticalContentAlignment="Center" Padding="8,0" Height="30"/>
                    </Border>
                    <TextBlock Text="&#xE721; Filter files by name..." IsHitTestVisible="False" Foreground="#9CA3AF" VerticalAlignment="Center" Margin="8,0,0,0">
                        <TextBlock.Style>
                            <Style TargetType="TextBlock"><Setter Property="Visibility" Value="Collapsed"/><Style.Triggers><DataTrigger Binding="{Binding Text, ElementName=SourceFilterBox}" Value=""><Setter Property="Visibility" Value="Visible"/></DataTrigger></Style.Triggers></Style>
                        </TextBlock.Style>
                    </TextBlock>
                </Grid>

                <DataGrid Name="SourceGrid" Grid.Row="3" BorderThickness="1">
                    <DataGrid.ContextMenu>
                        <ContextMenu>
                            <MenuItem Name="CtxOpenSourceLocation" Header="Open in Explorer">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" Foreground="#357790" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                            <MenuItem Name="CtxCopySourcePath" Header="Copy Full Path">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" Foreground="#357790" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                        </ContextMenu>
                    </DataGrid.ContextMenu>
                    <DataGrid.Columns>
                        <DataGridTemplateColumn Width="40">
                            <DataGridTemplateColumn.HeaderTemplate>
                                <DataTemplate>
                                    <CheckBox Name="SourceSelectAll" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.HeaderTemplate>
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <CheckBox IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="70" />
                        <DataGridTemplateColumn Header="Name" Width="*">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" Margin="4,0,0,0">
                                        <TextBlock Text="{Binding Icon}" FontFamily="Segoe MDL2 Assets" Foreground="{Binding IconColor}" FontSize="15" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                        <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Size" Binding="{Binding SizeStr}" Width="80" />
                        <DataGridTextColumn Header="Created" Binding="{Binding CreationTime}" Width="130" />
                    </DataGrid.Columns>
                </DataGrid>

                <!-- Action Button Bottom -->
                <Grid Grid.Row="4" Margin="0,8,0,0">
                    <Button Name="BtnStageSelected" Height="36" Background="#357790" Foreground="White" Padding="10,4" FontSize="14">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="+" FontSize="16" FontWeight="Bold" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Add Selected" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                </Grid>
            </Grid>

            <!-- Center Pane: Staging -->
            <Grid Grid.Column="1" Margin="12,0,12,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" SharedSizeGroup="HeaderRow" />
                    <RowDefinition Height="Auto" SharedSizeGroup="ToolbarRow" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" SharedSizeGroup="ActionRow" />
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" Text="2. COMBINED STAGING AREA REVIEW" FontWeight="Bold" FontSize="14" Foreground="#1E293B" VerticalAlignment="Center"/>
                
                <Grid Grid.Row="1" Margin="0,4,0,8" VerticalAlignment="Bottom">
                     <TextBlock Name="StagedTotalSize" Text="Items staged: 0 | Total: 0 B" Foreground="#4B5563" FontSize="13" VerticalAlignment="Bottom" Margin="0,0,0,6"/>
                </Grid>
                
                <DataGrid Name="StagingList" Grid.Row="2" SelectionMode="Extended" AllowDrop="True">
                    <DataGrid.ContextMenu>
                        <ContextMenu>
                            <MenuItem Name="CtxRemoveStaged" Header="Remove Selected">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Foreground="#DC6363" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                            <MenuItem Name="CtxOpenLocation" Header="Open Original Location">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" Foreground="#357790" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                            <MenuItem Name="CtxCopyStagedPath" Header="Copy Full Path">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" Foreground="#357790" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                        </ContextMenu>
                    </DataGrid.ContextMenu>
                    <DataGrid.Columns>
                        <DataGridTemplateColumn Width="40">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <CheckBox IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="60" />
                        <DataGridTemplateColumn Header="Name" Width="*">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" Margin="4,0,0,0">
                                        <TextBlock Text="{Binding Icon}" FontFamily="Segoe MDL2 Assets" Foreground="{Binding IconColor}" FontSize="15" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                        <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Size" Binding="{Binding SizeStr}" Width="80" />
                        <DataGridTextColumn Header="Original Source" Binding="{Binding SourceDisplay}" Width="130" />
                        <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="70" />
                    </DataGrid.Columns>
                </DataGrid>

                <Grid Grid.Row="3" Margin="0,8,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="1*"/>
                        <ColumnDefinition Width="1*"/>
                    </Grid.ColumnDefinitions>
                    <Button Name="BtnRemoveStaged" Grid.Column="0" Height="36" Background="#DC6363" Foreground="White" Padding="10,4" FontSize="14" Margin="0,0,6,0">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Remove Selected" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                    <Button Name="BtnClearStage" Grid.Column="1" Height="36" Style="{StaticResource SecondaryButton}" Padding="10,4" FontSize="14" Margin="6,0,0,0">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE894;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Clear All" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>
                </Grid>
            </Grid>

            <!-- Right Pane: Destination -->
            <Grid Grid.Column="2" Margin="12,0,0,0">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto" SharedSizeGroup="HeaderRow" />
                    <RowDefinition Height="Auto" SharedSizeGroup="ToolbarRow" />
                    <RowDefinition Height="*" />
                    <RowDefinition Height="Auto" SharedSizeGroup="ActionRow" />
                </Grid.RowDefinitions>
                
                <Grid Grid.Row="0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="3. CHOOSE DESTINATION" FontWeight="Bold" FontSize="14" Foreground="#1E293B" VerticalAlignment="Center"/>
                    <Border Grid.Column="1" HorizontalAlignment="Right" Width="140" Height="20" Background="#F3F7FA" BorderBrush="#B9CDD8" BorderThickness="1" CornerRadius="3" IsHitTestVisible="False">
                        <Grid>
                            <ProgressBar Name="DestFreeSpaceBar" Minimum="0" Maximum="100" Value="0" Background="Transparent" BorderThickness="0">
                                <ProgressBar.Foreground>
                                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
                                        <GradientStop Color="#357790" Offset="0"/>
                                        <GradientStop Color="#DC6363" Offset="1"/>
                                    </LinearGradientBrush>
                                </ProgressBar.Foreground>
                            </ProgressBar>
                            <TextBlock Name="DestSpaceText" Text="--%" HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="11" Foreground="Black" FontWeight="SemiBold"/>
                        </Grid>
                    </Border>
                </Grid>
                
                <Grid Grid.Row="1" Margin="0,4,0,8" VerticalAlignment="Bottom">
                     <Grid.ColumnDefinitions>
                         <ColumnDefinition Width="*"/>
                         <ColumnDefinition Width="Auto"/>
                         <ColumnDefinition Width="Auto"/>
                         <ColumnDefinition Width="Auto"/>
                         <ColumnDefinition Width="Auto"/>
                     </Grid.ColumnDefinitions>
                     
                     <Grid Grid.Column="0" Margin="0,0,8,0" VerticalAlignment="Bottom">
                        <Border BorderBrush="#B9CDD8" BorderThickness="1" CornerRadius="4" Margin="0,8,0,0" Background="White" Height="30" VerticalAlignment="Bottom">
                            <ComboBox Name="DestDriveCombo" BorderThickness="0" Background="Transparent" Style="{StaticResource ToolbarComboStyle}" IsEditable="True" Height="30" VerticalAlignment="Center"/>
                        </Border>
                        <TextBlock Text=" Active Destination " Background="#F4F6F8" Foreground="#4B5563" FontSize="12" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="8,0,0,0"/>
                     </Grid>
                     
                     <Button Name="DestRefreshButton" Grid.Column="1" Height="30" VerticalAlignment="Bottom" Content="&#xE72C;" Style="{StaticResource ToolbarButtonStyle}" ToolTip="Refresh"/>
                     <Button Name="DestNewFolderButton" Grid.Column="2" Height="30" VerticalAlignment="Bottom" Content="&#xE8F4;" Style="{StaticResource ToolbarButtonStyle}" ToolTip="New Folder"/>
                     <Button Name="DestDeleteButton" Grid.Column="3" Height="30" VerticalAlignment="Bottom" Content="&#xE74D;" Foreground="#DC6363" Style="{StaticResource ToolbarButtonStyle}" ToolTip="Delete Selected"/>
                     <Button Name="DestUpButton" Grid.Column="4" Height="30" VerticalAlignment="Bottom" Content="&#xE74A;" Style="{StaticResource ToolbarButtonStyle}" Margin="0" ToolTip="Up Folder"/>
                </Grid>
                
                <DataGrid Name="DestGrid" Grid.Row="2" BorderThickness="1">
                    <DataGrid.ContextMenu>
                        <ContextMenu>
                            <MenuItem Name="CtxDeleteDestSelected" Header="Delete Selected">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" Foreground="#DC6363" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                            <MenuItem Name="CtxOpenDestLocation" Header="Open in Explorer">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE838;" FontFamily="Segoe MDL2 Assets" Foreground="#357790" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                            <MenuItem Name="CtxCopyDestPath" Header="Copy Full Path">
                                <MenuItem.Icon>
                                    <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" Foreground="#357790" FontSize="14"/>
                                </MenuItem.Icon>
                            </MenuItem>
                        </ContextMenu>
                    </DataGrid.ContextMenu>
                    <DataGrid.Columns>
                        <DataGridTemplateColumn Width="40">
                            <DataGridTemplateColumn.HeaderTemplate>
                                <DataTemplate>
                                    <CheckBox Name="DestSelectAll" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.HeaderTemplate>
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <CheckBox IsChecked="{Binding IsSelected, UpdateSourceTrigger=PropertyChanged}" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Type" Binding="{Binding Type}" Width="70" />
                        <DataGridTemplateColumn Header="Name" Width="*">
                            <DataGridTemplateColumn.CellTemplate>
                                <DataTemplate>
                                    <StackPanel Orientation="Horizontal" Margin="4,0,0,0">
                                        <TextBlock Text="{Binding Icon}" FontFamily="Segoe MDL2 Assets" Foreground="{Binding IconColor}" FontSize="15" VerticalAlignment="Center" Margin="0,0,6,0"/>
                                        <TextBlock Text="{Binding Name}" VerticalAlignment="Center"/>
                                    </StackPanel>
                                </DataTemplate>
                            </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="Size" Binding="{Binding SizeStr}" Width="80" />
                    </DataGrid.Columns>
                </DataGrid>

                <Grid Grid.Row="3" Margin="0,8,0,0">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="1*"/>
                            <ColumnDefinition Width="1*"/>
                        </Grid.ColumnDefinitions>
                        
                        <Button Name="BtnCopyStaged" Grid.Column="0" Height="36" Background="#7B82B5" Foreground="White" Padding="10,4" FontSize="14" Margin="0,0,6,0">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE8C8;" FontFamily="Segoe MDL2 Assets" FontSize="15" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Copy" VerticalAlignment="Center"/>
                        </StackPanel>
                    </Button>

                        <Button Name="BtnMoveStaged" Grid.Column="1" Height="36" Background="#F2BC74" Foreground="Black" Padding="10,4" FontSize="14" Margin="6,0,0,0" ToolTip="Verify selection before move">
                        <StackPanel Orientation="Horizontal">
                            <TextBlock Text="&#xE8DE;" FontFamily="Segoe MDL2 Assets" FontSize="16" Margin="0,0,6,0" VerticalAlignment="Center"/>
                            <TextBlock Text="Move" VerticalAlignment="Center"/>
                        </StackPanel>
                        </Button>
                </Grid>
            </Grid>
        </Grid>

        <!-- Progress and Status Block at the absolute bottom -->
        <Grid Grid.Row="2" Margin="0,10,0,0">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            
            <Border Grid.Row="0" Height="8" Background="#E5E7EB" CornerRadius="4" Margin="0,0,0,6" ClipToBounds="True">
                <ProgressBar Name="TotalProgress" Minimum="0" Maximum="100" Value="0" BorderThickness="0" Background="Transparent" Foreground="#357790" />
            </Border>
            
            <Grid Grid.Row="1">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                
                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <TextBlock Name="StatusPrefixText" Text="Transfer Status: " Foreground="#1E293B" FontSize="13" FontWeight="SemiBold"/>
                    <TextBlock Name="StatusText" Text="Ready" Foreground="#1E293B" FontSize="13"/>
                    
                    <!-- Pause Button Inline -->
                    <Button Name="BtnPauseTransfer" Content="&#xE769; Pause" FontFamily="Segoe MDL2 Assets" Background="Transparent" Foreground="#EAB308" FontSize="13" FontWeight="Bold" ToolTip="Pause/Resume Transfer" Margin="15,0,0,0" Padding="0" BorderThickness="0" Cursor="Hand" Visibility="Collapsed">
                        <Button.Style>
                            <Style TargetType="Button">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="Button">
                                            <ContentPresenter/>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                                <Style.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter Property="Opacity" Value="0.2"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </Button.Style>
                    </Button>
                    <!-- Cancel Button Inline -->
                    <Button Name="BtnCancelTransfer" Content="&#xE711; Cancel" FontFamily="Segoe MDL2 Assets" Background="Transparent" Foreground="#DC2626" FontSize="13" FontWeight="Bold" ToolTip="Cancel Transfer" Margin="15,0,0,0" Padding="0" BorderThickness="0" Cursor="Hand" Visibility="Collapsed">
                        <Button.Style>
                            <Style TargetType="Button">
                                <Setter Property="Template">
                                    <Setter.Value>
                                        <ControlTemplate TargetType="Button">
                                            <ContentPresenter/>
                                        </ControlTemplate>
                                    </Setter.Value>
                                </Setter>
                                <Style.Triggers>
                                    <Trigger Property="IsEnabled" Value="False">
                                        <Setter Property="Opacity" Value="0.2"/>
                                    </Trigger>
                                </Style.Triggers>
                            </Style>
                        </Button.Style>
                    </Button>
                </StackPanel>
                
                <TextBlock Name="TransferStatsText" Grid.Column="1" Text="0 files copied (0 B total transferred) | Overall Progress [0%] | Est. Time: --" Foreground="#1E293B" FontSize="13" VerticalAlignment="Center"/>
            </Grid>
        </Grid>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $XAML)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Map controls
$BtnToggleHidden = $Window.FindName('BtnToggleHidden')
$SourceFilterBox = $Window.FindName('SourceFilterBox')
$SourceDriveCombo = $Window.FindName('SourceDriveCombo')
$DestDriveCombo = $Window.FindName('DestDriveCombo')
$SourceUpButton = $Window.FindName('SourceUpButton')
$DestUpButton = $Window.FindName('DestUpButton')
$SourceRefreshButton = $Window.FindName('SourceRefreshButton')
$DestRefreshButton = $Window.FindName('DestRefreshButton')
$DestNewFolderButton = $Window.FindName('DestNewFolderButton')
$DestDeleteButton = $Window.FindName('DestDeleteButton')

# Find the deeply nested SourceSelectAll manually since it's inside a HeaderTemplate
$SourceGrid = $Window.FindName('SourceGrid')
$CtxOpenSourceLocation = $Window.FindName('CtxOpenSourceLocation')
$CtxCopySourcePath = $Window.FindName('CtxCopySourcePath')
$DestGrid = $Window.FindName('DestGrid')
$CtxDeleteDestSelected = $Window.FindName('CtxDeleteDestSelected')
$CtxOpenDestLocation = $Window.FindName('CtxOpenDestLocation')
$CtxCopyDestPath = $Window.FindName('CtxCopyDestPath')
$DestFreeSpaceBar = $Window.FindName('DestFreeSpaceBar')
$DestSpaceText = $Window.FindName('DestSpaceText')

$StagingList = $Window.FindName('StagingList')
$BtnRemoveStaged = $Window.FindName('BtnRemoveStaged')
$CtxRemoveStaged = $Window.FindName('CtxRemoveStaged')
$CtxOpenLocation = $Window.FindName('CtxOpenLocation')
$CtxCopyStagedPath = $Window.FindName('CtxCopyStagedPath')
$BtnStageSelected = $Window.FindName('BtnStageSelected')
$BtnClearStage = $Window.FindName('BtnClearStage')
$StagedTotalSize = $Window.FindName('StagedTotalSize')
$BtnCopyStaged = $Window.FindName('BtnCopyStaged')
$BtnMoveStaged = $Window.FindName('BtnMoveStaged')
$BtnPauseTransfer = $Window.FindName('BtnPauseTransfer')
$BtnCancelTransfer = $Window.FindName('BtnCancelTransfer')

$TotalProgress = $Window.FindName('TotalProgress')
$StatusPrefixText = $Window.FindName('StatusPrefixText')
$StatusText = $Window.FindName('StatusText')
$TransferStatsText = $Window.FindName('TransferStatsText')

$script:SourceCurrentPath = ''
$script:DestCurrentPath = ''
$script:IsSyncingDriveCombo = $false
$script:ShowHiddenFiles = $false
$script:IsTransferInProgress = $false
$script:IsPaused = $false
$script:ActiveMover = $null
$script:TransferStopwatch = $null
$script:SourceAllItems = $null
$script:TransferredFileSet = $null
$script:StagedItems = New-Object System.Collections.ObjectModel.ObservableCollection[FileItem]
$script:SourceLoadGeneration = 0
$script:DestLoadGeneration = 0
$StagingList.ItemsSource = $script:StagedItems

function Format-Size {
    param([long]$bytes)
    if ($bytes -gt 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -gt 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -gt 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

function Get-FileIconInfo {
    param([bool]$IsContainer, [string]$Ext)
    if ($IsContainer) { return @{ Icon = [char]0xE8B7; Color = "#F59E0B" } } # Folder
    switch ($Ext.ToLower()) {
        { $_ -in '.jpg','.jpeg','.png','.gif','.bmp','.webp' } { return @{ Icon = [char]0xE8B9; Color = "#0EA5E9" } } # Image
        { $_ -in '.mp4','.mkv','.avi','.mov','.wmv' } { return @{ Icon = [char]0xE714; Color = "#EC4899" } } # Video
        { $_ -in '.mp3','.wav','.flac','.aac' } { return @{ Icon = [char]0xE8D6; Color = "#8B5CF6" } } # Audio
        { $_ -in '.zip','.rar','.7z','.tar','.gz' } { return @{ Icon = [char]0xE718; Color = "#EF4444" } } # Archive
        { $_ -in '.pdf' } { return @{ Icon = [char]0xEA90; Color = "#EF4444" } } # PDF
        { $_ -in '.exe','.msi','.bat','.cmd' } { return @{ Icon = [char]0xE756; Color = "#3B82F6" } } # App/Executable
        { $_ -in '.ps1','.cs','.js','.json','.xml','.html' } { return @{ Icon = [char]0xE943; Color = "#10B981" } } # Code
        default { return @{ Icon = [char]0xE7C3; Color = "#64748B" } } # Default Document
    }
}

function Format-Duration {
    param([double]$Seconds)

    if ($Seconds -le 0 -or [double]::IsNaN($Seconds) -or [double]::IsInfinity($Seconds)) {
        return '--'
    }

    $duration = [TimeSpan]::FromSeconds([math]::Ceiling($Seconds))
    if ($duration.TotalHours -ge 1) {
        return '{0:D2}:{1:D2}:{2:D2}' -f [int]$duration.TotalHours, $duration.Minutes, $duration.Seconds
    }

    return '{0:D2}:{1:D2}' -f $duration.Minutes, $duration.Seconds
}

function Get-AvailableDrives {
    # Include Local and Network Drives
    $drives = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.IsReady } |
        Select-Object -ExpandProperty Name
    Write-Output -NoEnumerate ([string[]]@($drives))
}

function Get-DriveComboItems {
    param([string]$CurrentPath)

    $items = New-Object 'System.Collections.Generic.List[string]'
    $normalizedCurrentPath = Normalize-DirectoryPath $CurrentPath
    $currentDriveRoot = $null
    if ($normalizedCurrentPath) {
        [void]$items.Add($normalizedCurrentPath)
        $currentDriveRoot = Normalize-DirectoryPath (Get-DriveRoot $normalizedCurrentPath)
    }

    foreach ($drive in @(Get-AvailableDrives)) {
        $normalizedDrive = Normalize-DirectoryPath $drive
        if (-not $normalizedDrive) { continue }
        if ($currentDriveRoot -and $normalizedCurrentPath -and $normalizedCurrentPath -ne $currentDriveRoot -and $normalizedDrive -eq $currentDriveRoot) {
            continue
        }
        if (-not $items.Contains($normalizedDrive)) {
            [void]$items.Add($normalizedDrive)
        }
    }

    Write-Output -NoEnumerate ([string[]]$items.ToArray())
}

function Get-DriveRoot {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    try {
        return [System.IO.Path]::GetPathRoot($Path)
    } catch {
        return $null
    }
}

function Get-DriveInfoForPath {
    param([string]$Path)

    $root = Get-DriveRoot $Path
    if (-not $root) { return $null }

    try {
        return [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and $_.Name -eq $root } | Select-Object -First 1
    } catch {
        return $null
    }
}

function Normalize-DirectoryPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }

    $candidate = $Path.Trim().Trim('"')
    if ($candidate -match '^[A-Za-z]$') {
        $candidate = '{0}:\' -f $candidate
    } elseif ($candidate -match '^[A-Za-z]:$') {
        $candidate = '{0}\' -f $candidate
    }

    try {
        if ([System.IO.File]::Exists($candidate)) {
            return [System.IO.Path]::GetDirectoryName($candidate)
        }

        $fullPath = [System.IO.Path]::GetFullPath($candidate)
        if ([System.IO.Directory]::Exists($fullPath)) {
            $root = [System.IO.Path]::GetPathRoot($fullPath)
            if ($fullPath -eq $root) {
                return $root
            }

            return $fullPath.TrimEnd('\')
        }
    } catch {
    }

    if ([System.IO.Directory]::Exists($candidate)) {
        return $candidate
    }

    return $null
}

function Sync-DriveComboSelection {
    param($ComboBox, [string]$CurrentPath)

    $script:IsSyncingDriveCombo = $true
    try {
        if ($ComboBox) {
            $ComboBox.ItemsSource = Get-DriveComboItems $CurrentPath
        }

        $ComboBox.SelectedItem = $null

        if ($CurrentPath) {
            $ComboBox.Text = $CurrentPath
        } else {
            $ComboBox.Text = ''
        }
    } finally {
        $script:IsSyncingDriveCombo = $false
    }
}

function Set-ControlEnabled {
    param(
        [object[]]$Controls,
        [bool]$Enabled
    )

    foreach ($control in $Controls) {
        if (-not $control) { continue }

        $property = $control.PSObject.Properties['IsEnabled']
        if ($property) {
            $control.IsEnabled = $Enabled
        }
    }
}

function Update-StagedActionState {
    $hasItems = $script:StagedItems.Count -gt 0
    # Any selected via check or highlighted row
    $selectedCount = @($script:StagedItems | Where-Object { $_.IsSelected }).Count + $StagingList.SelectedItems.Count
    $hasSelection = $selectedCount -gt 0

    if ($BtnRemoveStaged) { $BtnRemoveStaged.IsEnabled = $hasSelection }
    if ($CtxRemoveStaged) { $CtxRemoveStaged.IsEnabled = $hasSelection }
    if ($CtxOpenLocation) { $CtxOpenLocation.IsEnabled = $hasSelection }
    if ($CtxCopyStagedPath) { $CtxCopyStagedPath.IsEnabled = $hasSelection }
    if ($BtnClearStage) { $BtnClearStage.IsEnabled = $hasItems }
    if ($BtnCopyStaged) { $BtnCopyStaged.IsEnabled = $hasItems }
    if ($BtnMoveStaged) { $BtnMoveStaged.IsEnabled = $hasItems }
}

function Update-TransferState {
    if ($BtnCancelTransfer) {
        $BtnCancelTransfer.IsEnabled = $script:IsTransferInProgress
        $BtnCancelTransfer.Visibility = if ($script:IsTransferInProgress) { 'Visible' } else { 'Collapsed' }
    }

    if ($BtnPauseTransfer) {
        $BtnPauseTransfer.IsEnabled = $script:IsTransferInProgress
        $BtnPauseTransfer.Visibility = if ($script:IsTransferInProgress) { 'Visible' } else { 'Collapsed' }
    }

    if ($DestNewFolderButton) {
        $DestNewFolderButton.IsEnabled = -not $script:IsTransferInProgress
    }

    if ($DestDeleteButton) {
        $DestDeleteButton.IsEnabled = -not $script:IsTransferInProgress
    }
}

function Update-TransferSummary {
    param(
        [long]$Processed = 0,
        [long]$Total = 0,
        [string]$CurrentFile = ''
    )

    if (-not $TransferStatsText) { return }

    if (-not $script:TransferredFileSet) {
        $script:TransferredFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
    }

    if ($CurrentFile) {
        [void]$script:TransferredFileSet.Add($CurrentFile)
    }

    $fileCount = $script:TransferredFileSet.Count
    $percent = if ($Total -gt 0) { [math]::Round(($Processed / $Total) * 100, 0) } else { 0 }
    $eta = '--'
    $speedStr = '-- B/s'

    if ($script:TransferStopwatch -and $Processed -gt 0) {
        $elapsed = [math]::Max($script:TransferStopwatch.Elapsed.TotalSeconds, 0.001)
        $bytesPerSecond = $Processed / $elapsed
        $speedStr = "$(Format-Size ([long]$bytesPerSecond))/s"

        if ($bytesPerSecond -gt 0 -and $Total -gt $Processed) {
            $eta = Format-Duration (($Total - $Processed) / $bytesPerSecond)
        }
    }

    $verb = if ($fileCount -eq 1) { 'file processed' } else { 'files processed' }
    $TransferStatsText.Text = "{0} {1} ({2} streamed) | Speed: {3} | Overall Progress [{4}%] | Est. Time: {5}" -f $fileCount, $verb, (Format-Size $Processed), $speedStr, $percent, $eta
}

function Update-DestinationSummary {
    if (-not $DestFreeSpaceBar -or -not $DestSpaceText) { return }

    $drive = Get-DriveInfoForPath $script:DestCurrentPath
    if (-not $drive) {
        $DestFreeSpaceBar.Value = 0
        $DestSpaceText.Text = '--%'
        return
    }

    $used = [math]::Max($drive.TotalSize - $drive.AvailableFreeSpace, 0)
    $percentUsed = if ($drive.TotalSize -gt 0) { [math]::Round(($used / $drive.TotalSize) * 100, 0) } else { 0 }
    $DestFreeSpaceBar.Value = $percentUsed
    
    $freeStr = Format-Size $drive.AvailableFreeSpace
    $DestSpaceText.Text = "{0}% (Free: {1})" -f $percentUsed, $freeStr
}

function Reset-TransferUi {
    param(
        [object[]]$Controls,
        [string]$StatusMessage = "Ready"
    )

    if ($Controls) {
        Set-ControlEnabled -Controls $Controls -Enabled $true
    }

    $script:IsTransferInProgress = $false
    $script:IsPaused = $false
    if ($BtnPauseTransfer) {
        $BtnPauseTransfer.Content = "&#xE769; Pause"
    }

    $script:ActiveMover = $null
    $script:TransferStopwatch = $null
    $script:TransferredFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $TotalProgress.Maximum = 1
    $TotalProgress.Value = 0
    $StatusText.Text = $StatusMessage
    Update-TransferSummary -Processed 0 -Total 0
    Update-StagedActionState
    Update-TransferState
}

function New-DestinationFolder {
    $basePath = Resolve-RefreshPath $DestDriveCombo $script:DestCurrentPath
    if (-not $basePath -or -not [System.IO.Directory]::Exists($basePath)) {
        [System.Windows.MessageBox]::Show("Select a valid destination folder first.")
        return
    }

    $folderName = [Microsoft.VisualBasic.Interaction]::InputBox("Enter the name for the new folder.", "Create New Folder", "New Folder")
    if ([string]::IsNullOrWhiteSpace($folderName)) { return }

    $folderName = $folderName.Trim()
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    if ($folderName.IndexOfAny($invalidChars) -ge 0) {
        [System.Windows.MessageBox]::Show("The folder name contains invalid characters.")
        return
    }

    $newFolderPath = Join-Path $basePath $folderName
    if ([System.IO.Directory]::Exists($newFolderPath)) {
        [System.Windows.MessageBox]::Show("A folder with that name already exists.")
        return
    }

    try {
        [System.IO.Directory]::CreateDirectory($newFolderPath) | Out-Null
        $script:DestCurrentPath = $basePath
        Update-DestPane
        $StatusText.Text = "Created folder '$folderName'."
    } catch {
        [System.Windows.MessageBox]::Show("Unable to create the folder.`n$($_.Exception.Message)")
    }
}

function Resolve-RefreshPath {
    param(
        $ComboBox,
        [string]$CurrentPath
    )

    if ($ComboBox -and -not [string]::IsNullOrWhiteSpace($ComboBox.Text)) {
        $typedPath = Normalize-DirectoryPath $ComboBox.Text
        if ($typedPath) { return $typedPath }
    }

    $normalizedCurrentPath = Normalize-DirectoryPath $CurrentPath
    if ($normalizedCurrentPath) {
        return $normalizedCurrentPath
    }

    $driveRoot = Normalize-DirectoryPath (Get-DriveRoot $CurrentPath)
    if ($driveRoot) {
        return $driveRoot
    }

    if ($ComboBox -and $ComboBox.SelectedItem) {
        $selectedPath = Normalize-DirectoryPath ([string]$ComboBox.SelectedItem)
        if ($selectedPath) { return $selectedPath }
    }

    if (-not [string]::IsNullOrWhiteSpace($CurrentPath) -and [System.IO.Directory]::Exists($CurrentPath)) {
        return $CurrentPath
    }

    $availableDrives = Get-AvailableDrives
    if ($availableDrives.Count -gt 0) {
        return $availableDrives[0]
    }

    return ''
}

function Refresh-Drives {
    Sync-DriveComboSelection $SourceDriveCombo $script:SourceCurrentPath
    Sync-DriveComboSelection $DestDriveCombo $script:DestCurrentPath
}

function Refresh-SourcePane {
    Refresh-Drives
    $script:SourceCurrentPath = Resolve-RefreshPath $SourceDriveCombo $script:SourceCurrentPath
    if ($script:SourceCurrentPath -and [System.IO.Directory]::Exists($script:SourceCurrentPath)) {
        Update-SourcePane
    } else {
        $SourceGrid.ItemsSource = $null
        Sync-DriveComboSelection $SourceDriveCombo $script:SourceCurrentPath
    }
}

function Refresh-DestPane {
    Refresh-Drives
    $script:DestCurrentPath = Resolve-RefreshPath $DestDriveCombo $script:DestCurrentPath
    if ($script:DestCurrentPath -and [System.IO.Directory]::Exists($script:DestCurrentPath)) {
        Update-DestPane
    } else {
        $DestGrid.ItemsSource = $null
        Update-DestinationSummary
        Sync-DriveComboSelection $DestDriveCombo $script:DestCurrentPath
    }
}

# WMI Event Hook for Auto-refresh on USB Connect/Disconnect
$query = New-Object System.Management.WqlEventQuery("__InstanceOperationEvent", [TimeSpan]::FromSeconds(2), 'TargetInstance ISA "Win32_LogicalDisk"')
$watcher = New-Object System.Management.ManagementEventWatcher($query)
$watcherEventCallback = { 
    $Window.Dispatcher.Invoke([Action]{
        Refresh-Drives
    })
}
$eventJob = Register-ObjectEvent -InputObject $watcher -EventName "EventArrived" -Action $watcherEventCallback
$watcher.Start()

function Apply-SourceFilter {
    if (-not $script:SourceAllItems) { 
        $SourceGrid.ItemsSource = $null
        return 
    }
    $filterText = $SourceFilterBox.Text
    if ([string]::IsNullOrWhiteSpace($filterText)) {
        $SourceGrid.ItemsSource = $script:SourceAllItems
    } else {
        $filtered = $script:SourceAllItems | Where-Object { $_.Name -like "*$filterText*" }
        $SourceGrid.ItemsSource = New-Object System.Collections.ObjectModel.ObservableCollection[FileItem]($filtered)
    }
}

function Complete-DirectoryLoad {
    param($Grid, [string]$Path, [int]$Generation, [string]$SelectedPath, $LoadedItems, [string]$LoadError)

    if ($Grid -eq $SourceGrid) {
        if ($Generation -ne $script:SourceLoadGeneration -or $Path -ne $script:SourceCurrentPath) { return }
    } else {
        if ($Generation -ne $script:DestLoadGeneration -or $Path -ne $script:DestCurrentPath) { return }
    }
    $items = New-Object System.Collections.ObjectModel.ObservableCollection[FileItem]
    foreach ($f in $LoadedItems) {
        $isFolder = $f.Type -eq 'Folder'
        $ext = if ($isFolder) { '' } else { [System.IO.Path]::GetExtension($f.Name) }
        $iconInfo = Get-FileIconInfo -IsContainer $isFolder -Ext $ext
        $f.Icon = $iconInfo.Icon
        $f.IconColor = $iconInfo.Color
        $items.Add($f)
    }
    if ($LoadError) { $StatusText.Text = "Some entries in '$Path' could not be loaded. $LoadError" }
    if ($Grid -eq $SourceGrid) {
        $script:SourceAllItems = $items
        Apply-SourceFilter
    } else {
        $Grid.ItemsSource = $items
    }
    if ($SelectedPath) {
        $restoredItem = $items | Where-Object { $_.FullPath -eq $SelectedPath } | Select-Object -First 1
        if ($restoredItem) {
            $Grid.SelectedItem = $restoredItem
            $Grid.ScrollIntoView($restoredItem)
        }
    }
    if ($Grid -eq $DestGrid) { Update-DestinationSummary }
}

function Load-Files {
    param([string]$Path, $Grid)
    $normalizedPath = Normalize-DirectoryPath $Path
    if (-not $normalizedPath) { return }

    $selectedPath = $null
    if ($Grid.SelectedItem -and $Grid.SelectedItem.PSObject.Properties['FullPath']) {
        $selectedPath = $Grid.SelectedItem.FullPath
    }
    if ($Grid -eq $SourceGrid) {
        $script:SourceLoadGeneration++
        $generation = $script:SourceLoadGeneration
        $script:SourceAllItems = $null
    } else {
        $script:DestLoadGeneration++
        $generation = $script:DestLoadGeneration
    }
    $Grid.ItemsSource = $null
    $showHidden = [bool]$script:ShowHiddenFiles
    $gridRef = $Grid
    $pathRef = $normalizedPath
    $generationRef = $generation
    $selectedPathRef = $selectedPath
    $callbackScript = {
        param($loadedItems, $loadError)
        Complete-DirectoryLoad -Grid $gridRef -Path $pathRef -Generation $generationRef -SelectedPath $selectedPathRef -LoadedItems $loadedItems -LoadError $loadError
    }
    $callback = [System.Action[System.Collections.Generic.List[FileItem], string]]($callbackScript.GetNewClosure())
    [DirectoryLoader]::LoadAsync($normalizedPath, $showHidden, $Window.Dispatcher, $callback)
}

function Update-SourcePane {
    $script:SourceCurrentPath = Normalize-DirectoryPath $script:SourceCurrentPath
    Load-Files $script:SourceCurrentPath $SourceGrid
    Sync-DriveComboSelection $SourceDriveCombo $script:SourceCurrentPath
}

function Update-DestPane {
    $script:DestCurrentPath = Normalize-DirectoryPath $script:DestCurrentPath
    Load-Files $script:DestCurrentPath $DestGrid
    Sync-DriveComboSelection $DestDriveCombo $script:DestCurrentPath
    Update-DestinationSummary
}

function Apply-SourcePathInput {
    $path = Normalize-DirectoryPath $SourceDriveCombo.Text
    if (-not $path) { return }

    $script:SourceCurrentPath = $path
    Update-SourcePane
}

function Apply-DestPathInput {
    $path = Normalize-DirectoryPath $DestDriveCombo.Text
    if (-not $path) { return }

    $script:DestCurrentPath = $path
    Update-DestPane
}

# Events
$SourceDriveCombo.Add_SelectionChanged({
    if ($script:IsSyncingDriveCombo) { return }
    if ($SourceDriveCombo.SelectedItem) {
        $script:SourceCurrentPath = Normalize-DirectoryPath ([string]$SourceDriveCombo.SelectedItem)
        Update-SourcePane
    }
})

$DestDriveCombo.Add_SelectionChanged({
    if ($script:IsSyncingDriveCombo) { return }
    if ($DestDriveCombo.SelectedItem) {
        $script:DestCurrentPath = Normalize-DirectoryPath ([string]$DestDriveCombo.SelectedItem)
        Update-DestPane
    }
})

$SourceDriveCombo.Add_KeyUp({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        Apply-SourcePathInput
    }
})

$DestDriveCombo.Add_KeyUp({
    param($sender, $e)
    if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
        Apply-DestPathInput
    }
})

$SourceDriveCombo.Add_LostKeyboardFocus({
    if ($script:IsSyncingDriveCombo) { return }
    Apply-SourcePathInput
})

$DestDriveCombo.Add_LostKeyboardFocus({
    if ($script:IsSyncingDriveCombo) { return }
    Apply-DestPathInput
})

$BtnToggleHidden.Add_Click({
    $script:ShowHiddenFiles = -not $script:ShowHiddenFiles
    if ($script:ShowHiddenFiles) {
        $BtnToggleHidden.Foreground = "#357790"
        $BtnToggleHidden.ToolTip = "Show Hidden Files: ON"
    } else {
        $BtnToggleHidden.Foreground = "#374151"
        $BtnToggleHidden.ToolTip = "Show Hidden Files: OFF"
    }
    if ($script:SourceCurrentPath) { Update-SourcePane }
    if ($script:DestCurrentPath) { Update-DestPane }
})

$SourceFilterBox.Add_TextChanged({
    Apply-SourceFilter
})

$SourceUpButton.Add_Click({
    if ($script:SourceCurrentPath) {
        $parent = [System.IO.Directory]::GetParent($script:SourceCurrentPath)
        if ($parent) {
            $script:SourceCurrentPath = $parent.FullName
            Update-SourcePane
        }
    }
})

$SourceRefreshButton.Add_Click({
    $script:SourceCurrentPath = Resolve-RefreshPath $SourceDriveCombo $script:SourceCurrentPath
    Refresh-SourcePane
})
$DestRefreshButton.Add_Click({
    $script:DestCurrentPath = Resolve-RefreshPath $DestDriveCombo $script:DestCurrentPath
    Refresh-DestPane
})

$DestNewFolderButton.Add_Click({
    New-DestinationFolder
})

$DeleteDestAction = {
    if (-not $DestGrid.ItemsSource) { return }
    $selectedItems = @($DestGrid.ItemsSource | Where-Object { $_.IsSelected })
    if ($selectedItems.Count -eq 0) {
        $selectedItems = @($DestGrid.SelectedItems)
    }
    if ($selectedItems.Count -eq 0) { return }

    $msg = "Are you sure you want to permanently delete $($selectedItems.Count) item(s)?"
    $res = [System.Windows.MessageBox]::Show($msg, "Confirm Delete", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($res -eq 'Yes') {
        foreach ($item in $selectedItems) {
            try {
                if ($item.Type -eq 'Folder') {
                    [System.IO.Directory]::Delete($item.FullPath, $true)
                } else {
                    [System.IO.File]::Delete($item.FullPath)
                }
            } catch {
                [System.Windows.MessageBox]::Show("Failed to delete '$($item.Name)'.`n$($_.Exception.Message)")
            }
        }
        Update-DestPane
    }
}

$DestDeleteButton.Add_Click($DeleteDestAction)
$CtxDeleteDestSelected.Add_Click($DeleteDestAction)

$DestUpButton.Add_Click({
    if ($script:DestCurrentPath) {
        $parent = [System.IO.Directory]::GetParent($script:DestCurrentPath)
        if ($parent) {
            $script:DestCurrentPath = $parent.FullName
            Update-DestPane
        }
    }
})

$SourceGrid.Add_MouseDoubleClick({
    $selected = $SourceGrid.SelectedItem
    if ($selected.Type -eq 'Folder') {
        $script:SourceCurrentPath = $selected.FullPath
        Update-SourcePane
    }
})

$CtxOpenSourceLocation.Add_Click({
    $selected = $SourceGrid.SelectedItem
    if (-not $selected) { return }
    $target = $selected.FullPath
    if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) {
        Start-Process "explorer.exe" -ArgumentList "/select,`"$target`""
    }
})

$CtxCopySourcePath.Add_Click({
    $selected = $SourceGrid.SelectedItem
    if ($selected) {
        [System.Windows.Clipboard]::SetText($selected.FullPath)
    }
})

$DestGrid.Add_MouseDoubleClick({
    $selected = $DestGrid.SelectedItem
    if ($selected.Type -eq 'Folder') {
        $script:DestCurrentPath = $selected.FullPath
        Update-DestPane
    }
})

$CtxOpenDestLocation.Add_Click({
    $selected = $DestGrid.SelectedItem
    if (-not $selected) { return }
    $target = $selected.FullPath
    if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) {
        Start-Process "explorer.exe" -ArgumentList "/select,`"$target`""
    }
})

$CtxCopyDestPath.Add_Click({
    $selected = $DestGrid.SelectedItem
    if ($selected) {
        [System.Windows.Clipboard]::SetText($selected.FullPath)
    }
})

# Staging Logic
function Calculate-Staged-Size {
    if ($script:StagedItems.Count -eq 0) {
        $StagedTotalSize.Text = "Items staged: 0 | Total: 0 B"
        return
    }
    $paths = [string[]]@($script:StagedItems | Select-Object -ExpandProperty FullPath)
    $mover = New-Object FastFileMover
    $mover.UIDispatcher = $Window.Dispatcher
    $callback = [System.Action[long]]{
        param($totalBytes)
        $StagedTotalSize.Text = "Items staged: $($script:StagedItems.Count) | Total: $(Format-Size $totalBytes)"
    }
    $mover.CalculateStagedSizeAsync($paths, $callback)
}

$BtnStageSelected.Add_Click({
    $selectedItems = $SourceGrid.ItemsSource | Where-Object { $_.IsSelected }
    $added = $false
    foreach ($item in $selectedItems) {
        # Check if already staged to avoid duplicates
        $exists = $script:StagedItems | Where-Object { $_.FullPath -eq $item.FullPath }
        if (-not $exists) {
            $clone = New-Object FileItem
            $clone.Name = $item.Name
            $clone.FullPath = $item.FullPath
            $clone.Type = $item.Type
            $clone.Size = $item.Size
            $clone.SizeStr = $item.SizeStr
            $clone.Icon = $item.Icon
            $clone.IconColor = $item.IconColor
            $clone.CreationTime = $item.CreationTime
            $clone.SourceDisplay = $script:SourceCurrentPath
            $clone.Status = 'Ready'
            $clone.IsSelected = $false # start unchecked in staging
            $script:StagedItems.Add($clone)
            $item.IsSelected = $false
            $added = $true
        }
    }
    if ($added) { 
        Calculate-Staged-Size 
        $StagingList.ScrollIntoView($script:StagedItems[-1])
    }
    Update-StagedActionState
})

# Update logic to handle both StagingList grid selection AND checkbox IsSelected logic
$StagingList.Add_SelectionChanged({ Update-StagedActionState })
$StagingList.Add_CurrentCellChanged({ Update-StagedActionState })

$StagingList.Add_DragEnter({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $e.Effects = [System.Windows.DragDropEffects]::Copy
    } else {
        $e.Effects = [System.Windows.DragDropEffects]::None
    }
    $e.Handled = $true
})

$StagingList.Add_Drop({
    param($sender, $e)
    if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
        $droppedPaths = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
        $added = $false
        foreach ($path in $droppedPaths) {
            if ($script:StagedItems | Where-Object { $_.FullPath -eq $path }) { continue }

            $entry = Get-Item -LiteralPath $path -Force
            $clone = New-Object FileItem
            $clone.Name = $entry.Name
            $clone.FullPath = $entry.FullName
            $clone.SourceDisplay = [System.IO.Path]::GetDirectoryName($entry.FullName)
            $clone.Status = 'Ready'
            $clone.IsSelected = $false

            if ($entry.PSIsContainer) {
                $clone.Type = 'Folder'
                $clone.Size = 0
                $clone.SizeStr = ''
                $iconInfo = Get-FileIconInfo -IsContainer $true -Ext ""
            } else {
                $clone.Type = if ([string]::IsNullOrWhiteSpace($entry.Extension)) { 'File' } else { $entry.Extension }
                $clone.Size = $entry.Length
                $clone.SizeStr = Format-Size $clone.Size
                $iconInfo = Get-FileIconInfo -IsContainer $false -Ext $entry.Extension
            }
            $clone.Icon = $iconInfo.Icon
            $clone.IconColor = $iconInfo.Color
            $clone.CreationTime = $entry.CreationTime.ToString("yyyy-MM-dd HH:mm")
            $script:StagedItems.Add($clone)
            $added = $true
        }
        if ($added) { 
            Calculate-Staged-Size 
            $StagingList.ScrollIntoView($script:StagedItems[-1])
        }
        Update-StagedActionState
    }
})

$RemoveStagedAction = {
    # Identify items selected either via Checkbox or Grid Highlight
    $selectedItems = @($script:StagedItems | Where-Object { $_.IsSelected })
    if ($selectedItems.Count -eq 0) {
        $selectedItems = @($StagingList.SelectedItems)
    }
    if ($selectedItems.Count -eq 0) { return }

    foreach ($item in $selectedItems) {
        [void]$script:StagedItems.Remove($item)
    }

    Calculate-Staged-Size
    Update-StagedActionState
}

$BtnRemoveStaged.Add_Click($RemoveStagedAction)
$CtxRemoveStaged.Add_Click($RemoveStagedAction)

$CtxOpenLocation.Add_Click({
    $selectedItems = @($script:StagedItems | Where-Object { $_.IsSelected })
    if ($selectedItems.Count -eq 0) {
        $selectedItems = @($StagingList.SelectedItems)
    }
    if ($selectedItems.Count -eq 0) { return }

    $target = $selectedItems[0].FullPath
    if ([System.IO.File]::Exists($target) -or [System.IO.Directory]::Exists($target)) {
        Start-Process "explorer.exe" -ArgumentList "/select,`"$target`""
    }
})

$CtxCopyStagedPath.Add_Click({
    $selectedItems = @($script:StagedItems | Where-Object { $_.IsSelected })
    if ($selectedItems.Count -eq 0) {
        $selectedItems = @($StagingList.SelectedItems)
    }
    if ($selectedItems.Count -gt 0) {
        $target = $selectedItems[0].FullPath
        [System.Windows.Clipboard]::SetText($target)
    }
})

$BtnClearStage.Add_Click({
    if ($script:StagedItems.Count -eq 0) { return }

    $selectedItems = @($StagingList.SelectedItems)
    if ($selectedItems.Count -gt 0) {
        foreach ($item in $selectedItems) {
            [void]$script:StagedItems.Remove($item)
        }
    } else {
        $script:StagedItems.Clear()
    }

    Calculate-Staged-Size
    Update-StagedActionState
})

# Transfer Logic
function Start-Transfer([string]$DestPath, [bool]$Move) {
    if (-not $DestPath -or -not [System.IO.Directory]::Exists($DestPath)) {
        [System.Windows.MessageBox]::Show("Destination path is invalid.")
        return
    }
    
    if ($script:StagedItems.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No items in the staging queue.")
        return
    }
    
    $sourcePaths = [string[]]@($script:StagedItems | Select-Object -ExpandProperty FullPath)

    foreach ($source in $sourcePaths) {
        $targetPath = [System.IO.Path]::GetFullPath((Join-Path $DestPath ([System.IO.Path]::GetFileName($source))))
        $targetPath = $targetPath.TrimEnd([char[]]@('\','/'))
        $sourceFullPath = [System.IO.Path]::GetFullPath($source).TrimEnd([char[]]@('\','/'))
        if ($targetPath.Equals($sourceFullPath, [StringComparison]::OrdinalIgnoreCase) -or
            ([System.IO.Directory]::Exists($source) -and (
                $targetPath.StartsWith($sourceFullPath + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                $targetPath.StartsWith($sourceFullPath + [System.IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)))) {
                [System.Windows.MessageBox]::Show("The destination cannot be the same as, or inside, a staged source folder.", "Invalid Destination")
                return
        }
    }
    
    $ControlsToDisable = @($SourceDriveCombo, $DestDriveCombo, $BtnStageSelected, $BtnRemoveStaged, $CtxRemoveStaged, $BtnClearStage, $BtnCopyStaged, $BtnMoveStaged, $SourceGrid, $DestGrid, $StagingList, $SourceUpButton, $DestUpButton, $SourceRefreshButton, $DestRefreshButton, $DestNewFolderButton, $DestDeleteButton, $CtxDeleteDestSelected)
    Set-ControlEnabled -Controls $ControlsToDisable -Enabled $false
    $script:IsTransferInProgress = $true
    $script:TransferStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:TransferredFileSet = New-Object 'System.Collections.Generic.HashSet[string]'
    $StatusText.Text = "Calculating size..."
    Update-TransferSummary -Processed 0 -Total 0
    
    $mover = New-Object FastFileMover
    $script:ActiveMover = $mover
    $mover.UIDispatcher = $Window.Dispatcher
    $mover.UIPreflightAction = [System.Func[long, bool]]{
        param($estimatedBytes)
        $drive = Get-DriveInfoForPath $DestPath
        $available = if ($drive) { [long]$drive.AvailableFreeSpace } else { -1L }
        $conflictCount = 0
        foreach ($source in $sourcePaths) {
            $topLevelTarget = Join-Path $DestPath ([System.IO.Path]::GetFileName($source))
            if ([System.IO.File]::Exists($topLevelTarget) -or [System.IO.Directory]::Exists($topLevelTarget)) { $conflictCount++ }
        }
        $message = "Items: $($sourcePaths.Count)`nEstimated data: $(Format-Size $estimatedBytes)`nTop-level name conflicts: $conflictCount`nAvailable destination space: $(if ($available -ge 0) { Format-Size $available } else { 'Unavailable' })"
        if ($available -ge 0 -and $estimatedBytes -gt $available) {
            $message += "`n`nThe estimate exceeds available space. A move on the same volume may need less; continue anyway?"
        } else {
            $message += "`n`nNested folder conflicts may also be prompted during transfer. Continue?"
        }
        $answer = [System.Windows.MessageBox]::Show($message, "Transfer Preflight", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        return ($answer -eq [System.Windows.MessageBoxResult]::Yes)
    }
    Update-TransferState
    $mover.UIProgressAction = [System.Action[long, long, string]]{
        param($processed, $total, $file)
        if ($total -gt 0) { $TotalProgress.Maximum = $total } else { $TotalProgress.Maximum = 1 }
        $TotalProgress.Value = $processed
        Update-TransferSummary -Processed $processed -Total $total -CurrentFile $file
        if ($Move) {
            $StatusText.Text = 'Moving: ' + [System.IO.Path]::GetFileName($file)
        } else {
            $StatusText.Text = 'Copying: ' + [System.IO.Path]::GetFileName($file)
        }
    }

    function Show-OverwritePrompt([string]$FilePath) {
        $fileName = [System.Security.SecurityElement]::Escape([System.IO.Path]::GetFileName($FilePath))
        $xaml = @"
        <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                Title="File Conflict" Height="180" Width="620" WindowStartupLocation="CenterScreen" 
                ResizeMode="NoResize" Topmost="True" Background="#F4F6F8" FontFamily="Segoe UI" FontSize="14">
            <Window.Resources>
                <Style TargetType="Button">
                    <Setter Property="Padding" Value="8,4"/>
                    <Setter Property="Margin" Value="4"/>
                    <Setter Property="Background" Value="#E2E8F0"/>
                    <Setter Property="BorderThickness" Value="1"/>
                    <Setter Property="BorderBrush" Value="#CBD5E1"/>
                    <Setter Property="Cursor" Value="Hand"/>
                </Style>
            </Window.Resources>
            <Grid Margin="15">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>
                <TextBlock Grid.Row="0" TextWrapping="Wrap" Margin="0,0,0,10">
                    <Run Text="The file already exists in the destination:" FontWeight="SemiBold"/><LineBreak/>
                    <Run Text="$fileName" Foreground="#DC2626" FontWeight="SemiBold"/><LineBreak/><LineBreak/>
                    <Run Text="What would you like to do?"/>
                </TextBlock>
                <Grid Grid.Row="1">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button Name="BtnYes" Grid.Column="0" Content="Yes"/>
                    <Button Name="BtnYesAll" Grid.Column="1" Content="Yes to All"/>
                    <Button Name="BtnSkip" Grid.Column="2" Content="Skip"/>
                    <Button Name="BtnSkipAll" Grid.Column="3" Content="Skip All"/>
                    <Button Name="BtnKeep" Grid.Column="4" Content="Keep Both"/>
                    <Button Name="BtnKeepAll" Grid.Column="5" Content="Keep All"/>
                    <Button Name="BtnCancel" Grid.Column="6" Content="Cancel"/>
                </Grid>
            </Grid>
        </Window>
"@
        $reader = (New-Object System.Xml.XmlNodeReader ([xml]$xaml))
        $promptWindow = [Windows.Markup.XamlReader]::Load($reader)
        $promptWindow.Tag = 3
        $promptWindow.FindName('BtnYes').Add_Click({ $promptWindow.Tag = 1; $promptWindow.Close() })
        $promptWindow.FindName('BtnYesAll').Add_Click({ $promptWindow.Tag = 2; $promptWindow.Close() })
        $promptWindow.FindName('BtnSkip').Add_Click({ $promptWindow.Tag = 0; $promptWindow.Close() })
        $promptWindow.FindName('BtnSkipAll').Add_Click({ $promptWindow.Tag = 4; $promptWindow.Close() })
        $promptWindow.FindName('BtnKeep').Add_Click({ $promptWindow.Tag = 5; $promptWindow.Close() })
        $promptWindow.FindName('BtnKeepAll').Add_Click({ $promptWindow.Tag = 6; $promptWindow.Close() })
        $promptWindow.FindName('BtnCancel').Add_Click({ $promptWindow.Tag = 3; $promptWindow.Close() })
        $promptWindow.ShowDialog() | Out-Null
        return [int]$promptWindow.Tag
    }

    $mover.UIOverwritePrompt = [System.Func[string, int]]{
        param($file)
        return Show-OverwritePrompt $file
    }
    
    $onPreProcess = [System.Action]{
        if ($mover.TotalBytes -gt 0) { $TotalProgress.Maximum = $mover.TotalBytes } else { $TotalProgress.Maximum = 1 }
        $TotalProgress.Value = 0
        $StatusText.Text = "Starting transfer..."
        Update-TransferSummary -Processed 0 -Total $mover.TotalBytes
        Update-TransferState
    }

    $onComplete = [System.Action]{
        if ($Move) {
            foreach ($staged in @($script:StagedItems)) {
                if (-not [System.IO.File]::Exists($staged.FullPath) -and -not [System.IO.Directory]::Exists($staged.FullPath)) {
                    [void]$script:StagedItems.Remove($staged)
                }
            }
            Calculate-Staged-Size
        }
        Update-SourcePane
        Update-DestPane
        
        $statusMsg = if ($mover.IsCancelled) { "Cancelled" } elseif ($mover.FailedCount -gt 0 -or $mover.SkippedCount -gt 0) { "Finished with issues" } else { "Transfer finished" }
        $statusMsg += ": $($mover.SuccessCount) succeeded, $($mover.SkippedCount) skipped, $($mover.FailedCount) failed."
        $warningCount = @($mover.TransferLog | Where-Object { $_ -match '\[(SIZE WARNING|METADATA WARNING|WARNING)\]' }).Count
        if ($warningCount -gt 0) { $statusMsg += " $warningCount warning(s); see transfer log." }
        
        if ($mover.TransferLog.Count -gt 0) {
            $logFileName = "TransferLog_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff')_$([guid]::NewGuid().ToString('N').Substring(0, 8)).txt"
            $logPath = Join-Path $DestPath $logFileName
            try {
                [System.IO.File]::WriteAllLines($logPath, $mover.TransferLog.ToArray())
                $statusMsg += " (Log saved to destination)"
            } catch {
                $statusMsg += " (Failed to save log)"
            }
        }

        Reset-TransferUi -Controls $ControlsToDisable -StatusMessage $statusMsg
    }

    $mover.ProcessItemsAsync($sourcePaths, $DestPath, $Move, $onPreProcess, $onComplete)
}

$BtnCopyStaged.Add_Click({ Start-Transfer $script:DestCurrentPath $false })
$BtnMoveStaged.Add_Click({ Start-Transfer $script:DestCurrentPath $true })
$BtnPauseTransfer.Add_Click({
    if (-not $script:IsTransferInProgress -or -not $script:ActiveMover) { return }

    if ($script:IsPaused) {
        $script:IsPaused = $false
        $BtnPauseTransfer.Content = "&#xE769; Pause"
        $script:ActiveMover.PauseEvent.Set() | Out-Null
        $script:TransferStopwatch.Start()
        $StatusText.Text = $StatusText.Text -replace "^Paused: ", ""
    } else {
        $script:IsPaused = $true
        $BtnPauseTransfer.Content = "&#xE768; Resume"
        $script:ActiveMover.PauseEvent.Reset() | Out-Null
        $script:TransferStopwatch.Stop()
        $StatusText.Text = "Paused: " + $StatusText.Text
    }
})

$BtnCancelTransfer.Add_Click({
    if (-not $script:IsTransferInProgress -or -not $script:ActiveMover) { return }

    $confirmation = [System.Windows.MessageBox]::Show(
        "Cancel the current transfer? Files already copied will remain in the destination.",
        "Cancel Transfer",
        [System.Windows.MessageBoxButton]::YesNo,
        [System.Windows.MessageBoxImage]::Question
    )

    if ($confirmation -ne [System.Windows.MessageBoxResult]::Yes) { return }

    $script:ActiveMover.IsCancelled = $true
    $script:ActiveMover.PauseEvent.Set() | Out-Null # Unblock thread if paused
    $StatusText.Text = "Cancelling transfer..."
    $BtnCancelTransfer.IsEnabled = $false
})

# Initialization
Refresh-Drives
$drives = Get-AvailableDrives

if ($drives.Count -gt 0) {
    $script:SourceCurrentPath = $drives[0]
}
if ($drives.Count -gt 1) {
    $script:DestCurrentPath = $drives[1]
} elseif ($drives.Count -gt 0) {
    $script:DestCurrentPath = $drives[0]
}

if ($script:SourceCurrentPath) { 
    $SourceDriveCombo.SelectedItem = $script:SourceCurrentPath
    Update-SourcePane 
}
if ($script:DestCurrentPath) { 
    $DestDriveCombo.SelectedItem = $script:DestCurrentPath
    Update-DestPane 
}

Update-StagedActionState
Reset-TransferUi -StatusMessage "Ready"

$Window.Add_Closing({
    param($sender, $e)
    if ($script:IsTransferInProgress) {
        $e.Cancel = $true
        $confirmation = [System.Windows.MessageBox]::Show(
            "A transfer is still running. Cancel it and wait for it to finish before closing?",
            "Transfer in Progress",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning
        )
        if ($confirmation -eq [System.Windows.MessageBoxResult]::Yes -and $script:ActiveMover) {
            $script:ActiveMover.IsCancelled = $true
            $script:ActiveMover.PauseEvent.Set() | Out-Null
            $StatusText.Text = "Cancelling transfer before close..."
        }
    }
})

$Window.Add_Closed({
    # Cleanup event hook when window closes
    Unregister-Event -SourceIdentifier "EventArrived" -ErrorAction SilentlyContinue
    if ($eventJob) { Remove-Job -Job $eventJob -Force -ErrorAction SilentlyContinue }
    $watcher.Stop()
    $watcher.Dispose()
})

$Window.ShowDialog() | Out-Null
