# .\scripts\interface.ps1

# Import required modules
Import-Module "$PSScriptRoot\utility.ps1"
Import-Module "$PSScriptRoot\model.ps1"
Import-Module "$PSScriptRoot\internet.ps1"

# Add Avalonia assemblies
Add-Type -Path ".\lib\Avalonia.dll"
Add-Type -Path ".\lib\Avalonia.Desktop.dll"
Add-Type -Path ".\lib\Avalonia.Controls.dll"

# Initialize settings
$settings = Get-Settings
$global:UIConfig = @{
    AutoSave = $settings.AutoBackup
    AutoSaveInterval = $settings.AutoSaveInterval
}

# Event handlers
$global:UIEvents = @{
    NodeOperations = @{
        OnSelect = { 
            param($Node) 
            $global:TempVars.CurrentNode = $Node
            Update-ContentPanel 
        }
        OnCreate = { 
            param($ParentNode, $Title = "New Node")
            $newNode = New-TreeNode -Title $Title -ParentId $ParentNode.Id
            Save-TreeNode -Node $newNode
            Update-TreeView
            Show-StatusMessage "Node created successfully" "Success"
            return $newNode
        }
        OnDelete = {
            param($Node)
            if (Show-Confirmation "Delete Node" "Are you sure you want to delete this node?") {
                Remove-TreeNode -NodeId $Node.Id
                Update-TreeView
                Show-StatusMessage "Node deleted" "Success"
                return $true
            }
            return $false
        }
        OnEdit = {
            param($Node, $Content)
            $Node.Content = $Content
            Save-TreeNode -Node $Node
            Show-StatusMessage "Changes saved" "Success"
        }
    }
    Chat = @{
        OnMessageReceived = {
            param($Message, $Context)
            $global:MainWindow.ProcessChatMessage($Message, $Context)
        }
        OnCommandExecuted = {
            param($Command, $Result)
            $global:MainWindow.HandleCommandResult($Command, $Result)
        }
    }
    Search = @{
        OnChange = { param($Text) Update-TreeViewFilter -Filter $Text }
    }
}

# Auto-save manager
class AutoSaveManager {
    [System.Timers.Timer]$Timer
    [scriptblock]$SaveCallback
    
    AutoSaveManager([scriptblock]$callback) {
        $settings = Get-Settings
        $this.SaveCallback = $callback
        $this.Timer = [System.Timers.Timer]::new($settings.AutoSaveInterval * 1000)
        $this.Timer.Elapsed += {
            if ($settings.AutoBackup) {
                try {
                    & $this.SaveCallback
                    Show-StatusMessage "Auto-saved" "Success"
                }
                catch {
                    Show-StatusMessage "Auto-save failed: $_" "Error"
                }
            }
        }
    }
    
    [void]Start() { $this.Timer.Start() }
    [void]Stop() { $this.Timer.Stop() }
}

class ChatState {
    [bool]$IsProcessing
    [string]$CurrentContext
    [hashtable]$LastCommand
    [System.Collections.Generic.List[hashtable]]$History
    [int]$MaxMessageSize = 4000
    
    ChatState() {
        $this.IsProcessing = $false
        $this.CurrentContext = ""
        $this.LastCommand = $null
        $this.History = [System.Collections.Generic.List[hashtable]]::new()
    }
    
    [void]AddMessage([string]$Role, [string]$Message) {
        $this.History.Add(@{
            Role = $Role
            Message = $Message
            Timestamp = Get-Date
        })
        
        # Keep history size manageable
        while ($this.History.Count > 100) {
            $this.History.RemoveAt(0)
        }
    }
    
    [array]GetRecentHistory([int]$Count) {
        $start = [Math]::Max(0, $this.History.Count - $Count)
        return $this.History.GetRange($start, [Math]::Min($Count, $this.History.Count - $start))
    }
}

# Main window class
class MainWindow : Avalonia.Controls.Window {
    # UI Components
    $TreeView
    $SearchBox
    $ContentBox
    $ChatPanel
    $ChatInput
    $ChatOutput
    $ChatSendButton
    $StatusText
    $StatusProgress
    $AutoSaveManager
    
    # Chat State
    $ChatHistory = @()
    $IsProcessingMessage = $false
    $LastCommand = $null
    
    MainWindow() {
        # Load XAML
        $xaml = [System.IO.File]::ReadAllText("$PSScriptRoot\interface.xaml")
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        [Avalonia.Markup.Xaml.AvaloniaXamlLoader]::Load($this, $reader)
        
        $this.InitializeComponents()
        $this.InitializeAutoSave()
        $this.InitializeCommands()
        
        # Apply theme from settings
        $settings = Get-Settings
        $this.Theme = $settings.Theme
    }
    
    [void]InitializeComponents() {
        # Get controls
        $this.TreeView = $this.FindName("DocumentTree")
        $this.SearchBox = $this.FindName("SearchBox")
        $this.ContentBox = $this.FindName("ContentBox")
        $this.ChatPanel = $this.FindName("ChatPanel")
        $this.ChatInput = $this.FindName("ChatInput")
        $this.ChatOutput = $this.FindName("ChatOutput")
        $this.ChatSendButton = $this.FindName("ChatSendButton")
        $this.StatusText = $this.FindName("StatusText")
        $this.StatusProgress = $this.FindName("StatusProgress")
        
        # Tree and Content handlers
        $this.TreeView.SelectionChanged += { $global:UIEvents.NodeOperations.OnSelect.Invoke($_.AddedItems[0]) }
        $this.ContentBox.TextChanged += { 
            if ($global:TempVars.CurrentNode) {
                $global:UIEvents.NodeOperations.OnEdit.Invoke($global:TempVars.CurrentNode, $_.Text)
            }
        }
        
        # Search handler
        $this.SearchBox.TextChanged += { $global:UIEvents.Search.OnChange.Invoke($_.Text) }
        
        # Chat handlers
        $this.ChatSendButton.Click += { $this.ProcessChatMessage($this.ChatInput.Text) }
        $this.ChatInput.KeyDown += {
            param($sender, $e)
            if ($e.Key -eq [Avalonia.Input.Key]::Enter -and -not $e.KeyModifiers) {
                $this.ProcessChatMessage($this.ChatInput.Text)
                $e.Handled = $true
            }
        }
        
        # Initialize chat output
        $this.ChatOutput.IsReadOnly = $true
        $this.ChatOutput.TextWrapping = [Avalonia.Media.TextWrapping]::Wrap
        $this.AppendChatMessage("System", "Chat interface initialized. Ready to assist.")
    }
    
    [void]ProcessChatMessage([string]$Message, [hashtable]$AdditionalContext = @{}) {
        if ($this.IsProcessingMessage -or [string]::IsNullOrWhiteSpace($Message)) {
            return
        }
        
        try {
            $this.IsProcessingMessage = $true
            $this.ChatSendButton.IsEnabled = $false
            $this.ChatInput.IsEnabled = $false
            
            # Add user message to chat
            $this.AppendChatMessage("User", $Message)
            $this.ChatInput.Text = ""
            
            # Build context
            $context = @{
                CurrentNode = $global:TempVars.CurrentNode
                CurrentNodeContent = if ($global:TempVars.CurrentNode) {
                    Get-TreeNodeContent $global:TempVars.CurrentNode.TextHash
                } else { $null }
                LastCommand = $this.LastCommand
            }
            
            # Add additional context
            foreach ($key in $AdditionalContext.Keys) {
                $context[$key] = $AdditionalContext[$key]
            }
            
            # Get AI response
            $result = Send-ChatPrompt -Message $Message -Context $context
            
            # Add response to chat
            $this.AppendChatMessage("Assistant", $result.Message)
            
            # Process commands
            foreach ($command in $result.Commands) {
                $this.ExecuteAICommand($command)
            }
        }
        catch {
            $this.AppendChatMessage("System", "Error: $_")
        }
        finally {
            $this.IsProcessingMessage = $false
            $this.ChatSendButton.IsEnabled = $true
            $this.ChatInput.IsEnabled = $true
        }
    }
    
    [void]AppendChatMessage([string]$Sender, [string]$Message) {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $formattedMessage = "[$timestamp] $Sender:`n$Message`n`n"
        
        $this.ChatOutput.Text += $formattedMessage
        $this.ChatOutput.CaretIndex = $this.ChatOutput.Text.Length
        $this.ChatOutput.ScrollToEnd()
        
        # Add to history
        $this.ChatHistory += @{
            Timestamp = $timestamp
            Sender = $Sender
            Message = $Message
        }
        
        # Keep chat history within reasonable limits
        if ($this.ChatHistory.Count > 100) {
            $this.ChatHistory = $this.ChatHistory[-100..-1]
        }
    }
    
    [void]ExecuteAICommand([hashtable]$Command) {
        $this.LastCommand = $Command
        
        try {
            switch ($Command.Type) {
                "CreateNode" {
                    $title = $Command.Parameters[0]
                    $this.AppendChatMessage("System", "Creating new node: $title")
                    $newNode = $global:UIEvents.NodeOperations.OnCreate.Invoke(
                        $global:TempVars.CurrentNode, 
                        $title
                    )
                    if ($newNode) {
                        $global:TempVars.CurrentNode = $newNode
                        Update-ContentPanel
                    }
                }
                "UpdateNode" {
                    if ($global:TempVars.CurrentNode) {
                        $content = $Command.Parameters[0]
                        $this.AppendChatMessage("System", "Updating node content")
                        $global:UIEvents.NodeOperations.OnEdit.Invoke(
                            $global:TempVars.CurrentNode, 
                            $content
                        )
                    }
                }
                "DeleteNode" {
                    if ($global:TempVars.CurrentNode) {
                        $this.AppendChatMessage("System", "Deleting current node")
                        $global:UIEvents.NodeOperations.OnDelete.Invoke($global:TempVars.CurrentNode)
                    }
                }
                "GenerateContent" {
                    $type = $Command.Parameters[0]
                    $prompt = $Command.Parameters[1]
                    $this.AppendChatMessage("System", "Generating $type content...")
                    
                    switch ($type) {
                        "Text" {
                            $content = Send-TextPrompt -Prompt $prompt -Options @{
                                Temperature = 0.7
                                MaxTokens = 2000
                            }
                            if ($global:TempVars.CurrentNode) {
                                $global:UIEvents.NodeOperations.OnEdit.Invoke(
                                    $global:TempVars.CurrentNode, 
                                    $content
                                )
                            }
                        }
                        "Image" {
                            $imageType = Get-ContentType -Description $prompt
                            $this.AppendChatMessage(
                                "System", 
                                "Detected image type: $imageType. Generating..."
                            )
                            # Image generation will be implemented here
                        }
                    }
                }
                "Research" {
                    $query = $Command.Parameters[0]
                    $this.AppendChatMessage("System", "Researching: $query")
                    $results = Get-WebResearch -Query $query
                    $this.AppendChatMessage("System", "Research complete")
                    $this.ProcessChatMessage("Research results found", @{
                        ResearchResults = $results
                    })
                }
            }
        }
        catch {
            $this.AppendChatMessage("System", "Command execution failed: $_")
        }
    }
    
    [void]HandleCommandResult($Command, $Result) {
        if ($Result.Success) {
            $this.AppendChatMessage("System", "Command completed: $($Command.Type)")
        }
        else {
            $this.AppendChatMessage("System", "Command failed: $($Result.Error)")
        }
    }
    
    [void]InitializeAutoSave() {
        $this.AutoSaveManager = [AutoSaveManager]::new({
            if ($global:TempVars.CurrentNode) {
                Save-TreeNode -Node $global:TempVars.CurrentNode
            }
        })
        $this.AutoSaveManager.Start()
    }
    
    [void]InitializeCommands() {
        # Menu commands
        $this.FindName("NewNodeCommand").Execute += { 
            $global:UIEvents.NodeOperations.OnCreate.Invoke($global:TempVars.CurrentNode) 
        }
        $this.FindName("SaveCommand").Execute += { 
            if ($global:TempVars.CurrentNode) {
                Save-TreeNode -Node $global:TempVars.CurrentNode
                Show-StatusMessage "Saved successfully" "Success"
            }
        }
        $this.FindName("ExitCommand").Execute += { $this.Close() }
        
        # Keyboard shortcuts
        $this.KeyDown += {
            param($sender, $e)
            if ($e.KeyModifiers -eq [Avalonia.Input.KeyModifiers]::Control) {
                switch ($e.Key) {
                    ([Avalonia.Input.Key]::S) {
                        if ($global:TempVars.CurrentNode) {
                            Save-TreeNode -Node $global:TempVars.CurrentNode
                            Show-StatusMessage "Saved successfully" "Success"
                            $e.Handled = $true
                        }
                    }
                    ([Avalonia.Input.Key]::N) {
                        if ($global:TempVars.CurrentNode) {
                            $global:UIEvents.NodeOperations.OnCreate.Invoke(
                                $global:TempVars.CurrentNode
                            )
                            $e.Handled = $true
                        }
                    }
                }
            }
        }
    }
}

# UI utility functions
function Show-Confirmation {
    param(
        [string]$Title,
        [string]$Message
    )
    $result = $false
    
    $dialog = $global:MainWindow.FindName("ConfirmationDialog")
    $dialog.Title = $Title
    $dialog.FindName("MessageText").Text = $Message
    
    $dialog.FindName("OKButton").Click += { $result = $true; $dialog.Close() }
    $dialog.FindName("CancelButton").Click += { $dialog.Close() }
    
    $dialog.ShowDialog($global:MainWindow)
    return $result
}

function Show-StatusMessage {
    param(
        [string]$Message,
        [string]$Type = "Info"
    )
    $color = switch ($Type) {
        "Success" { "Green" }
        "Warning" { "Orange" }
        "Error" { "Red" }
        default { "Black" }
    }
    
    $global:MainWindow.StatusText.Text = $Message
    $global:MainWindow.StatusText.Foreground = [Avalonia.Media.SolidColorBrush]::Parse($color)
}

function Show-Progress {
    param(
        [int]$Value,
        [string]$Message
	)
    $global:MainWindow.StatusProgress.Value = $Value
    $global:MainWindow.StatusProgress.IsVisible = $Value -gt 0 -and $Value -lt 100
    
    if ($Message) {
        Show-StatusMessage $Message
    }
}

function Update-TreeView {
    $treeData = Get-TreeData
    $global:MainWindow.TreeView.Items = ConvertTo-TreeViewItems $treeData.root
}

function Update-TreeViewFilter {
    param([string]$Filter)
    if ([string]::IsNullOrWhiteSpace($Filter)) {
        Update-TreeView
        return
    }
    
    $treeData = Get-TreeData
    $filteredItems = Convert-TreeNodeToViewModel $treeData.root | 
        Where-Object { $_.Title -like "*$Filter*" }
    $global:MainWindow.TreeView.Items = $filteredItems
}

function Update-ContentPanel {
    if ($global:TempVars.CurrentNode) {
        $content = Get-TreeNodeContent $global:TempVars.CurrentNode.TextHash
        if ($content) {
            $global:MainWindow.ContentBox.Text = $content
        }
        else {
            $global:MainWindow.ContentBox.Text = ""
        }
    }
    else {
        $global:MainWindow.ContentBox.Text = ""
    }
}

function Initialize-AvaloniaUI {
    try {
        $appBuilder = [Avalonia.AppBuilder]::Configure[[LightStoneApp]]()
            .UsePlatformDetect()
            .LogToTrace()
        return $appBuilder.StartWithClassicDesktopLifetime(@())
    }
    catch {
        Write-Error "Failed to initialize Avalonia UI: $_"
        return $false
    }
}

function Start-LightStoneInterface {
    param([hashtable]$Config)
    
    try {
        if (-not (Initialize-AvaloniaUI)) {
            throw "Failed to initialize Avalonia UI"
        }
        
        $global:MainWindow = [MainWindow]::new()
        Update-TreeView
        $global:MainWindow.Show()
        return $true
    }
    catch {
        Write-Error "Failed to start interface: $_"
        return $false
    }
}

# View Management
class ViewManager {
    [string]$CurrentView
    [hashtable]$Panels
    [hashtable]$GridColumns
    [hashtable]$LastSizes

    ViewManager() {
        $this.CurrentView = "split"
        $this.Panels = @{}
        $this.GridColumns = @{}
        $this.LastSizes = @{
            tree = 300
            chat = 300
        }
    }

    [void]Initialize([Avalonia.Controls.Grid]$contentGrid) {
        # Store column definitions
        $this.GridColumns["tree"] = $contentGrid.ColumnDefinitions[0]
        $this.GridColumns["splitter1"] = $contentGrid.ColumnDefinitions[1]
        $this.GridColumns["content"] = $contentGrid.ColumnDefinitions[2]
        $this.GridColumns["splitter2"] = $contentGrid.ColumnDefinitions[3]
        $this.GridColumns["chat"] = $contentGrid.ColumnDefinitions[4]

        # Store panel references
        $this.Panels["tree"] = $contentGrid.Children | Where-Object { $_.Name -eq "DocumentTree" }
        $this.Panels["content"] = $contentGrid.Children | Where-Object { $_.Name -eq "ContentBox" }
        $this.Panels["chat"] = $contentGrid.Children | Where-Object { $_.Name -eq "ChatPanel" }
    }

    [void]SetView([string]$viewMode) {
        $this.CurrentView = $viewMode
        
        switch ($viewMode) {
            "split" {
                $this.GridColumns["tree"].Width = [Avalonia.Controls.GridLength]::new($this.LastSizes.tree)
                $this.GridColumns["splitter1"].Width = [Avalonia.Controls.GridLength]::new(3)
                $this.GridColumns["content"].Width = [Avalonia.Controls.GridLength]::new(1, [Avalonia.Controls.GridUnitType]::Star)
                $this.GridColumns["splitter2"].Width = [Avalonia.Controls.GridLength]::new(3)
                $this.GridColumns["chat"].Width = [Avalonia.Controls.GridLength]::new($this.LastSizes.chat)
            }
            "tree" {
                $this.StoreCurrentSizes()
                $this.GridColumns["tree"].Width = [Avalonia.Controls.GridLength]::new(1, [Avalonia.Controls.GridUnitType]::Star)
                $this.GridColumns["splitter1"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["content"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["splitter2"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["chat"].Width = [Avalonia.Controls.GridLength]::new(0)
            }
            "chat" {
                $this.StoreCurrentSizes()
                $this.GridColumns["tree"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["splitter1"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["content"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["splitter2"].Width = [Avalonia.Controls.GridLength]::new(0)
                $this.GridColumns["chat"].Width = [Avalonia.Controls.GridLength]::new(1, [Avalonia.Controls.GridUnitType]::Star)
            }
        }

        $this.UpdatePanelVisibility()
    }

    [void]StoreCurrentSizes() {
        if ($this.CurrentView -eq "split") {
            $this.LastSizes.tree = $this.GridColumns["tree"].Width.Value
            $this.LastSizes.chat = $this.GridColumns["chat"].Width.Value
        }
    }

    [void]UpdatePanelVisibility() {
        foreach ($panel in $this.Panels.Values) {
            $column = [Avalonia.Controls.Grid]::GetColumn($panel)
            $width = $this.GridColumns[$column].Width.Value
            $panel.IsVisible = $width -gt 0
        }
    }
}

# Progress Management
class ProgressManager {
    [Avalonia.Controls.ProgressBar]$ProgressBar
    [Avalonia.Controls.TextBlock]$StatusText
    [hashtable]$Tasks
    [int]$ActiveTasks

    ProgressManager([Avalonia.Controls.ProgressBar]$progress, [Avalonia.Controls.TextBlock]$status) {
        $this.ProgressBar = $progress
        $this.StatusText = $status
        $this.Tasks = @{}
        $this.ActiveTasks = 0
    }

    [string]StartTask([string]$description) {
        $taskId = [Guid]::NewGuid().ToString()
        $this.Tasks[$taskId] = @{
            Description = $description
            StartTime = Get-Date
            Progress = 0
        }
        $this.ActiveTasks++
        $this.UpdateUI()
        return $taskId
    }

    [void]UpdateTask([string]$taskId, [int]$progress, [string]$status = $null) {
        if ($this.Tasks.ContainsKey($taskId)) {
            $this.Tasks[$taskId].Progress = $progress
            if ($status) {
                $this.Tasks[$taskId].Description = $status
            }
            $this.UpdateUI()
        }
    }

    [void]CompleteTask([string]$taskId) {
        if ($this.Tasks.ContainsKey($taskId)) {
            $this.Tasks.Remove($taskId)
            $this.ActiveTasks--
            $this.UpdateUI()
        }
    }

    [void]UpdateUI() {
        if ($this.ActiveTasks -eq 0) {
            $this.ProgressBar.IsVisible = $false
            $this.StatusText.Text = "Ready"
        } else {
            $this.ProgressBar.IsVisible = $true
            $totalProgress = ($this.Tasks.Values | Measure-Object -Property Progress -Average).Average
            $this.ProgressBar.Value = $totalProgress

            if ($this.Tasks.Count -eq 1) {
                $task = $this.Tasks.Values | Select-Object -First 1
                $this.StatusText.Text = "$($task.Description) - $($task.Progress)%"
            } else {
                $this.StatusText.Text = "$($this.ActiveTasks) tasks in progress - $([Math]::Round($totalProgress))%"
            }
        }
    }
}

# Clipboard Management
class ClipboardManager {
    [object]$Clipboard
    [hashtable]$History
    [int]$MaxHistory

    ClipboardManager([int]$maxHistory = 10) {
        $this.Clipboard = [Avalonia.Input.Clipboard]::Instance
        $this.History = @{}
        $this.MaxHistory = $maxHistory
    }

    [void]SetText([string]$text) {
        $this.Clipboard.SetTextAsync($text)
        $this.AddToHistory($text)
    }

    [string]GetText() {
        return $this.Clipboard.GetTextAsync().Result
    }

    [void]AddToHistory([string]$text) {
        $timestamp = Get-Date
        $this.History[$timestamp] = $text

        # Maintain history limit
        while ($this.History.Count -gt $this.MaxHistory) {
            $oldest = $this.History.Keys | Sort-Object | Select-Object -First 1
            $this.History.Remove($oldest)
        }
    }

    [array]GetHistory() {
        return $this.History.Keys | Sort-Object -Descending | ForEach-Object {
            @{
                Timestamp = $_
                Text = $this.History[$_]
            }
        }
    }
}

# Window State Management
class WindowStateManager {
    [Avalonia.Controls.Window]$Window
    [hashtable]$LastPosition
    [hashtable]$LastSize

    WindowStateManager([Avalonia.Controls.Window]$window) {
        $this.Window = $window
        $this.LoadState()
    }

    [void]LoadState() {
        $settings = Get-Settings
        if ($settings.WindowState) {
            $this.LastPosition = $settings.WindowState.Position
            $this.LastSize = $settings.WindowState.Size
        } else {
            $this.LastPosition = @{ X = 100; Y = 100 }
            $this.LastSize = @{ Width = 800; Height = 600 }
        }
    }

    [void]SaveState() {
        $state = @{
            Position = @{
                X = $this.Window.Position.X
                Y = $this.Window.Position.Y
            }
            Size = @{
                Width = $this.Window.Width
                Height = $this.Window.Height
            }
        }

        $settings = Get-Settings
        $settings.WindowState = $state
        Set-Settings -Settings $settings
    }

    [void]RestoreState() {
        $this.Window.Position = [Avalonia.PixelPoint]::new(
            $this.LastPosition.X,
            $this.LastPosition.Y
        )
        $this.Window.Width = $this.LastSize.Width
        $this.Window.Height = $this.LastSize.Height
    }
}

# Update MainWindow class
class MainWindow : Avalonia.Controls.Window {
    # Additional properties
    [ViewManager]$ViewManager
    [ProgressManager]$ProgressManager
    [ClipboardManager]$ClipboardManager
    [WindowStateManager]$StateManager
    
    # Constructor update
    MainWindow() {
        # Initialize managers
        $this.ViewManager = [ViewManager]::new()
        $this.ClipboardManager = [ClipboardManager]::new()
        $this.StateManager = [WindowStateManager]::new($this)
        
        # Load XAML and initialize components (existing code)
        $xaml = [System.IO.File]::ReadAllText("$PSScriptRoot\interface.xaml")
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
        [Avalonia.Markup.Xaml.AvaloniaXamlLoader]::Load($this, $reader)
        
        $this.InitializeComponents()
        $this.InitializeManagers()
        $this.InitializeAutoSave()
        $this.InitializeCommands()
        
        # Apply theme from settings
        $settings = Get-Settings
        $this.Theme = $settings.Theme
        
        # Restore window state
        $this.StateManager.RestoreState()
    }
    
    # Initialize managers
    [void]InitializeManagers() {
        # Initialize ViewManager
        $contentGrid = $this.FindName("ContentGrid")
        $this.ViewManager.Initialize($contentGrid)
        
        # Initialize ProgressManager
        $progressBar = $this.FindName("StatusProgress")
        $statusText = $this.FindName("StatusText")
        $this.ProgressManager = [ProgressManager]::new($progressBar, $statusText)
    }
    
    # Override OnClosed
    [void]OnClosed() {
        $this.StateManager.SaveState()
        if ($this.AutoSaveManager) {
            $this.AutoSaveManager.Stop()
        }
    }
}

# Export functions
Export-ModuleMember -Function *