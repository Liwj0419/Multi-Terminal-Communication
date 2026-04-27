using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace LocalLink.Windows;

public partial class MainWindow : Window
{
    private readonly LocalLinkViewModel model = new();
    private readonly Brush page = Paint("#F7F8FB");
    private readonly Brush surface = Brushes.White;
    private readonly Brush ink = Paint("#1C2026");
    private readonly Brush muted = Paint("#64707C");
    private readonly Brush line = Paint("#E0E4EC");
    private readonly Brush blue = Paint("#16408F");
    private DiscoveredPeer? selectedPeer;
    private PanelKind selectedPanel = PanelKind.Messages;

    public MainWindow()
    {
        InitializeComponent();
        model.Changed += Render;
        model.Error += message => MessageBox.Show(this, message, "LocalLink", MessageBoxButton.OK, MessageBoxImage.Information);
        model.PairRequested += ShowPairRequest;
        Loaded += (_, _) =>
        {
            model.Start();
            Render();
        };
        Closed += (_, _) => model.Stop();
    }

    private void Render()
    {
        Root.Children.Clear();
        Root.ColumnDefinitions.Clear();
        Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(300) });
        Root.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        Root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var sidebar = Sidebar();
        Grid.SetColumn(sidebar, 0);
        Root.Children.Add(sidebar);

        var separator = new System.Windows.Controls.Border { Width = 1, Background = line };
        Grid.SetColumn(separator, 1);
        Root.Children.Add(separator);

        var detail = selectedPeer is null ? EmptyDetail() : PeerDetail(model.Resolve(selectedPeer));
        Grid.SetColumn(detail, 2);
        Root.Children.Add(detail);
    }

    private UIElement Sidebar()
    {
        var root = new DockPanel { Background = page, LastChildFill = true };
        var title = new Grid { Margin = new Thickness(18, 16, 18, 10) };
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        title.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        title.Children.Add(new TextBlock
        {
            Text = "LocalLink",
            FontSize = 28,
            FontWeight = FontWeights.SemiBold,
            Foreground = ink,
            VerticalAlignment = VerticalAlignment.Center
        });
        title.Children.Add(IconActionButton(model.IsRunning ? "Ⅱ" : "▶", () =>
        {
            if (model.IsRunning) model.Stop(); else model.Start();
        }, 1));
        title.Children.Add(IconActionButton("⚙", ShowSettings, 2));
        DockPanel.SetDock(title, Dock.Top);
        root.Children.Add(title);

        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var stack = new StackPanel { Margin = new Thickness(14, 0, 14, 18) };
        stack.Children.Add(SectionTitle("Nearby"));
        if (model.DiscoveredPeers.Count == 0)
        {
            stack.Children.Add(EmptyCard("Searching on this Wi-Fi."));
        }
        else
        {
            foreach (var peer in model.DiscoveredPeers)
            {
                stack.Children.Add(PeerRow(peer));
            }
        }

        stack.Children.Add(SectionTitle("Trusted"));
        if (model.TrustedPeers.Count == 0)
        {
            stack.Children.Add(EmptyCard("No paired devices"));
        }
        else
        {
            foreach (var trusted in model.TrustedPeers)
            {
                var peer = model.PeerForTrusted(trusted);
                if (peer is not null)
                {
                    stack.Children.Add(PeerRow(peer));
                }
            }
        }

        scroll.Content = stack;
        root.Children.Add(scroll);
        return root;
    }

    private UIElement PeerDetail(DiscoveredPeer peer)
    {
        var root = new DockPanel { Background = page };
        var header = Header(peer);
        DockPanel.SetDock(header, Dock.Top);
        root.Children.Add(header);
        var composer = Composer(peer);
        DockPanel.SetDock(composer, Dock.Bottom);
        root.Children.Add(composer);

        var content = new StackPanel { Margin = new Thickness(22, 14, 22, 16) };
        content.Children.Add(Tabs());
        content.Children.Add(ContentPanel(peer));
        root.Children.Add(new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto });
        return root;
    }

    private UIElement Header(DiscoveredPeer peer)
    {
        var connected = model.ConnectedPeerIDs.Contains(peer.identity.deviceID);
        var grid = new Grid { Margin = new Thickness(22, 18, 22, 12) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(new TextBlock { Text = PlatformIcon(peer.identity.platform), FontSize = 24, Foreground = muted, Margin = new Thickness(0, 0, 10, 0) });
        left.Children.Add(new TextBlock { Text = peer.identity.displayName, FontSize = 22, FontWeight = FontWeights.SemiBold, Foreground = ink });
        grid.Children.Add(left);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        actions.Children.Add(Chip(peer.isTrusted ? connected ? "Connected" : "Paired" : "Not paired", connected ? "#0F825D" : "#64707C"));
        if (!peer.isTrusted)
        {
            actions.Children.Add(ActionButton("Pair", true, () => model.Pair(peer), false));
        }
        else if (connected)
        {
            actions.Children.Add(ActionButton("Disconnect", true, () => model.Disconnect(peer.identity.deviceID), true));
        }
        else
        {
            actions.Children.Add(ActionButton("Connect", !string.IsNullOrWhiteSpace(peer.host) && peer.port > 0, () => model.Connect(peer), false));
        }
        Grid.SetColumn(actions, 1);
        grid.Children.Add(actions);
        return grid;
    }

    private UIElement Tabs()
    {
        var grid = new UniformGrid { Columns = 3, Margin = new Thickness(0, 0, 0, 14) };
        foreach (var panel in Enum.GetValues<PanelKind>())
        {
            grid.Children.Add(new Button
            {
                Content = panel.ToString(),
                Height = 40,
                Margin = new Thickness(2),
                Background = selectedPanel == panel ? surface : Paint("#EBEEF4"),
                Foreground = selectedPanel == panel ? blue : muted,
                BorderBrush = line,
                BorderThickness = new Thickness(1),
                Command = new RelayCommand(() =>
                {
                    selectedPanel = panel;
                    Render();
                })
            });
        }
        return grid;
    }

    private UIElement ContentPanel(DiscoveredPeer peer)
    {
        return selectedPanel switch
        {
            PanelKind.Messages => Card(MessagesPanel(peer)),
            PanelKind.Pictures => Card(TransfersPanel(peer, true)),
            _ => Card(TransfersPanel(peer, false))
        };
    }

    private UIElement MessagesPanel(DiscoveredPeer peer)
    {
        var stack = new StackPanel();
        stack.Children.Add(PanelTitle("Messages"));
        var messages = model.Messages.Where(message => message.peerID == peer.identity.deviceID).TakeLast(80).ToList();
        if (messages.Count == 0)
        {
            stack.Children.Add(Text("No messages", muted, 15));
        }
        else
        {
            foreach (var message in messages)
            {
                stack.Children.Add(MessageBubble(message));
            }
        }
        return stack;
    }

    private UIElement TransfersPanel(DiscoveredPeer peer, bool pictures)
    {
        var stack = new StackPanel();
        stack.Children.Add(PanelTitle(pictures ? "Pictures" : "Files"));
        var transfers = model.Transfers
            .Where(transfer => transfer.peerID == peer.identity.deviceID && transfer.IsPicture == pictures)
            .ToList();
        if (transfers.Count == 0)
        {
            stack.Children.Add(Text(pictures ? "No pictures" : "No files", muted, 15));
        }
        else
        {
            foreach (var transfer in transfers)
            {
                stack.Children.Add(TransferRow(transfer));
            }
        }
        return stack;
    }

    private UIElement Composer(DiscoveredPeer peer)
    {
        var connected = model.ConnectedPeerIDs.Contains(peer.identity.deviceID);
        var grid = new Grid { Margin = new Thickness(22), Background = page };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var attach = IconActionButton("📎", () => PickFile(peer), 0);
        attach.IsEnabled = connected;
        grid.Children.Add(attach);

        var input = new TextBox
        {
            Height = 38,
            Margin = new Thickness(10, 0, 10, 0),
            VerticalContentAlignment = VerticalAlignment.Center,
            BorderBrush = line,
            Background = surface
        };
        input.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter)
            {
                model.SendText(peer, input.Text);
                input.Text = "";
            }
        };
        Grid.SetColumn(input, 1);
        grid.Children.Add(input);

        var send = ActionButton("Send", connected, () =>
        {
            model.SendText(peer, input.Text);
            input.Text = "";
        }, false);
        Grid.SetColumn(send, 2);
        grid.Children.Add(send);
        return grid;
    }

    private UIElement TransferRow(TransferItem transfer)
    {
        var row = new Grid { Margin = new Thickness(0, 8, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel();
        left.Children.Add(Text(transfer.fileName, ink, 15, true));
        left.Children.Add(Text($"{FormatBytes(transfer.completedBytes)} / {FormatBytes(transfer.totalBytes)}", muted, 13));
        left.Children.Add(new ProgressBar { Height = 6, Value = transfer.Progress * 100, Maximum = 100, Margin = new Thickness(0, 7, 12, 0) });
        row.Children.Add(left);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        if (transfer.IsPicture)
        {
            actions.Children.Add(ActionButton("View", true, () => ViewPicture(transfer), false));
        }
        actions.Children.Add(ActionButton(transfer.downloadedPath is null ? "Download" : "Downloaded", transfer.downloadedPath is null && transfer.status == TransferStatus.complete, () => Download(transfer), false));
        actions.Children.Add(ActionButton("Show", transfer.downloadedPath is not null, () => ShowInExplorer(transfer.downloadedPath), false));
        Grid.SetColumn(actions, 1);
        row.Children.Add(actions);
        return row;
    }

    private UIElement PeerRow(DiscoveredPeer peer)
    {
        var selected = selectedPeer?.identity.deviceID == peer.identity.deviceID;
        var row = new Grid
        {
            Margin = new Thickness(0, 0, 0, 8),
            Background = selected ? Paint("#E8EFFF") : surface,
            MinHeight = 62,
            Cursor = System.Windows.Input.Cursors.Hand
        };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        row.Children.Add(new TextBlock { Text = PlatformIcon(peer.identity.platform), FontSize = 20, Foreground = muted, Margin = new Thickness(14, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center });
        var labels = new StackPanel { Margin = new Thickness(0, 10, 8, 10) };
        labels.Children.Add(Text(peer.identity.displayName, ink, 15));
        labels.Children.Add(Text(peer.isTrusted ? "Paired" : peer.EndpointDescription, muted, 12));
        Grid.SetColumn(labels, 1);
        row.Children.Add(labels);
        var chip = Chip(model.ConnectedPeerIDs.Contains(peer.identity.deviceID) ? "Connected" : peer.isTrusted ? "Paired" : "Nearby", model.ConnectedPeerIDs.Contains(peer.identity.deviceID) ? "#0F825D" : "#64707C");
        Grid.SetColumn(chip, 2);
        row.Children.Add(chip);
        row.MouseLeftButtonUp += (_, _) =>
        {
            selectedPeer = peer;
            selectedPanel = PanelKind.Messages;
            Render();
        };
        return Border(row, selected ? "#16408F" : "#E0E4EC");
    }

    private void ShowSettings()
    {
        var window = new Window
        {
            Owner = this,
            Title = "Settings",
            Width = 720,
            Height = 620,
            MinWidth = 680,
            MinHeight = 520,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = page
        };
        var stack = new StackPanel { Margin = new Thickness(22) };
        stack.Children.Add(PanelTitle("This Device"));
        var name = new TextBox { Text = model.LocalIdentity.displayName, Height = 36, VerticalContentAlignment = VerticalAlignment.Center, BorderBrush = line, Background = surface };
        var nameRow = SettingsRow("Name", name);
        nameRow.Children.Add(ActionButton("Save", true, () => model.UpdateDeviceName(name.Text), false));
        stack.Children.Add(nameRow);
        stack.Children.Add(Text($"ID {model.LocalIdentity.deviceID[..8]}", muted, 13));
        stack.Children.Add(SectionTitle("Connection"));
        var addresses = model.ConnectionAddresses.ToList();
        var addressText = Text(addresses.Count == 0 ? "Start LocalLink to show this device address." : addresses[0], muted, 13);
        addressText.FontFamily = new FontFamily("Consolas");
        var addressRow = SettingsRow("This PC", addressText);
        if (addresses.Count > 0)
        {
            addressRow.Children.Add(ActionButton("Copy", true, () => Clipboard.SetText(addresses[0]), false));
        }
        stack.Children.Add(addressRow);
        var manual = new TextBox
        {
            Height = 36,
            VerticalContentAlignment = VerticalAlignment.Center,
            BorderBrush = line,
            Background = surface
        };
        manual.KeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Enter)
            {
                model.ConnectManually(manual.Text);
                window.Close();
            }
        };
        var manualRow = SettingsRow("Manual", manual);
        manualRow.Children.Add(ActionButton("Connect", true, () =>
        {
            model.ConnectManually(manual.Text);
            window.Close();
        }, false));
        stack.Children.Add(manualRow);
        stack.Children.Add(SectionTitle("Trusted Devices"));
        if (model.TrustedPeers.Count == 0)
        {
            stack.Children.Add(EmptyCard("No paired devices"));
        }
        foreach (var peer in model.TrustedPeers)
        {
            var card = new Grid();
            card.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            card.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var details = new StackPanel();
            details.Children.Add(Text(peer.displayName, ink, 15, true));
            details.Children.Add(Text($"{peer.platform}  {peer.deviceID[..8]}", muted, 13));
            if (!string.IsNullOrWhiteSpace(peer.lastHost) && peer.lastPort > 0)
            {
                details.Children.Add(Text($"Last endpoint {peer.lastHost}:{peer.lastPort}", muted, 12));
            }
            Grid.SetColumn(details, 0);
            card.Children.Add(details);
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(16, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center };
            actions.Children.Add(ActionButton("Clear Messages", true, () => model.ClearMessages(peer.deviceID), false));
            actions.Children.Add(ActionButton("Clear Transfers", true, () => model.ClearTransfers(peer.deviceID), false));
            actions.Children.Add(ActionButton("Forget", true, () => model.Forget(peer.deviceID), true));
            Grid.SetColumn(actions, 1);
            card.Children.Add(actions);
            stack.Children.Add(Card(card));
        }
        window.Content = new ScrollViewer { Content = stack };
        window.ShowDialog();
        Render();
    }

    private StackPanel SettingsRow(string label, UIElement content)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = new Thickness(0, 8, 0, 8),
            VerticalAlignment = VerticalAlignment.Center
        };
        row.Children.Add(new TextBlock
        {
            Text = label,
            Width = 84,
            Foreground = muted,
            TextAlignment = TextAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 0, 12, 0)
        });
        if (content is FrameworkElement element)
        {
            element.MinWidth = 360;
            element.VerticalAlignment = VerticalAlignment.Center;
        }
        row.Children.Add(content);
        return row;
    }

    private void ShowPairRequest(DeviceIdentity identity, string code)
    {
        var result = MessageBox.Show(
            this,
            $"Pair with {identity.displayName}?\n\nCode: {code}",
            "LocalLink Pairing",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Question);
        if (result == MessageBoxResult.OK)
        {
            model.ConfirmPairing(identity);
        }
    }

    private void PickFile(DiscoveredPeer peer)
    {
        var dialog = new OpenFileDialog { Title = "Send file", CheckFileExists = true };
        if (dialog.ShowDialog(this) == true)
        {
            model.SendFile(peer, dialog.FileName);
        }
    }

    private void Download(TransferItem transfer)
    {
        try
        {
            var path = model.Download(transfer);
            ShowInExplorer(path);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "LocalLink", MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    private void ViewPicture(TransferItem transfer)
    {
        var data = model.TransferData(transfer);
        if (data is null)
        {
            MessageBox.Show(this, "Picture is no longer in memory. Downloaded files remain available.", "LocalLink");
            return;
        }

        var image = new Image { Stretch = Stretch.Uniform, MaxHeight = 620 };
        using var stream = new MemoryStream(data);
        var bitmap = new BitmapImage();
        bitmap.BeginInit();
        bitmap.CacheOption = BitmapCacheOption.OnLoad;
        bitmap.StreamSource = stream;
        bitmap.EndInit();
        image.Source = bitmap;
        new Window
        {
            Owner = this,
            Title = transfer.fileName,
            Width = 760,
            Height = 620,
            Content = new ScrollViewer { Content = image },
            WindowStartupLocation = WindowStartupLocation.CenterOwner
        }.ShowDialog();
    }

    private static void ShowInExplorer(string? path)
    {
        if (path is null)
        {
            return;
        }

        Process.Start("explorer.exe", $"/select,\"{path}\"");
    }

    private UIElement EmptyDetail() =>
        new Grid
        {
            Background = page,
            Children =
            {
                new TextBlock
                {
                    Text = "Select a Device",
                    FontSize = 28,
                    Foreground = muted,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center
                }
            }
        };

    private UIElement MessageBubble(ConversationMessage message)
    {
        var wrapper = new StackPanel
        {
            HorizontalAlignment = message.isOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left,
            Margin = new Thickness(0, 4, 0, 8)
        };
        wrapper.Children.Add(new TextBlock
        {
            Text = message.isOutgoing ? "Me" : "Peer",
            Foreground = muted,
            FontSize = 11,
            HorizontalAlignment = message.isOutgoing ? HorizontalAlignment.Right : HorizontalAlignment.Left
        });
        wrapper.Children.Add(Border(new TextBlock
        {
            Text = message.text,
            Foreground = message.isOutgoing ? Brushes.White : ink,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            Margin = new Thickness(10, 7, 10, 7)
        }, message.isOutgoing ? "#16408F" : "#F1F4F9", 0));
        return wrapper;
    }

    private UIElement Card(UIElement child) => Border(child, "#FFFFFF", 10, "#E0E4EC", new Thickness(0, 0, 0, 10), new Thickness(16, 14, 16, 14));
    private UIElement EmptyCard(string text) => Card(Text(text, muted, 15));
    private UIElement SectionTitle(string text) => Text(text, ink, 18, true, new Thickness(0, 18, 0, 8));
    private UIElement PanelTitle(string text) => Text(text, ink, 17, true, new Thickness(0, 0, 0, 10));

    private static TextBlock Text(string text, Brush brush, double size, bool bold = false, Thickness? margin = null) =>
        new()
        {
            Text = text,
            Foreground = brush,
            FontSize = size,
            FontWeight = bold ? FontWeights.SemiBold : FontWeights.Normal,
            Margin = margin ?? new Thickness(0),
            TextWrapping = TextWrapping.Wrap
        };

    private System.Windows.Controls.Button ActionButton(string text, bool enabled, Action action, bool danger) =>
        new()
        {
            Content = text,
            IsEnabled = enabled,
            Margin = new Thickness(8, 0, 0, 0),
            Padding = new Thickness(12, 6, 12, 6),
            Foreground = danger ? Paint("#B93741") : blue,
            Background = Paint("#F4F7FC"),
            BorderBrush = line,
            Command = new RelayCommand(action)
        };

    private System.Windows.Controls.Button IconActionButton(string text, Action action, int column)
    {
        var button = new Button
        {
            Content = text,
            Width = 42,
            Height = 42,
            Margin = new Thickness(8, 0, 0, 0),
            Foreground = blue,
            Background = Paint("#E8EFFF"),
            BorderBrush = Paint("#E8EFFF"),
            Command = new RelayCommand(action)
        };
        Grid.SetColumn(button, column);
        return button;
    }

    private UIElement Chip(string text, string color)
    {
        var chip = Border(new TextBlock
        {
            Text = text,
            Foreground = Paint(color),
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(10, 4, 10, 4)
        }, "#F2F4F8", 999);
        ((FrameworkElement)chip).Margin = new Thickness(8, 0, 0, 0);
        ((FrameworkElement)chip).VerticalAlignment = VerticalAlignment.Center;
        return chip;
    }

    private static System.Windows.Controls.Border Border(UIElement child, string background, double radius = 10, string? border = null, Thickness? margin = null, Thickness? padding = null) =>
        new()
        {
            Child = child,
            Background = Paint(background),
            BorderBrush = border is null ? Brushes.Transparent : Paint(border),
            BorderThickness = border is null ? new Thickness(0) : new Thickness(1),
            CornerRadius = new CornerRadius(radius),
            Margin = margin ?? new Thickness(0),
            Padding = padding ?? new Thickness(0)
        };

    private static SolidColorBrush Paint(string hex) => new((Color)ColorConverter.ConvertFromString(hex));

    private static string PlatformIcon(DevicePlatform platform) =>
        platform switch
        {
            DevicePlatform.iOS => "i",
            DevicePlatform.macOS => "M",
            DevicePlatform.android => "A",
            DevicePlatform.windows => "W",
            _ => "?"
        };

    private static string FormatBytes(long bytes)
    {
        if (bytes < 1024) return $"{bytes} B";
        var kb = bytes / 1024.0;
        if (kb < 1024) return $"{kb:0.0} KB";
        return $"{kb / 1024.0:0.0} MB";
    }

    private enum PanelKind
    {
        Messages,
        Pictures,
        Files
    }
}
