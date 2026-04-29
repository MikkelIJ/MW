using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace MW;

public partial class PickerWindow : Window
{
    private readonly RegionStore _store;
    private readonly ScreenInfo _screen;
    private readonly Action<Region> _onPicked;

    public PickerWindow(RegionStore store, IReadOnlyList<ScreenInfo> screens, Action<Region> onPicked)
    {
        InitializeComponent();
        _store = store;
        _onPicked = onPicked;
        _screen = screens.FirstOrDefault(s => s.IsPrimary) ?? screens[0];
        Left = _screen.Bounds.X; Top = _screen.Bounds.Y;
        Width = _screen.Bounds.Width; Height = _screen.Bounds.Height;
        Loaded += (_, _) => DrawRegions();
    }

    private void DrawRegions()
    {
        var regions = _store.Regions(_screen.Key);
        if (regions.Count == 0)
        {
            var hint = new TextBlock
            {
                Text = "No regions on this display yet.\nUse Edit Regions… first.",
                Foreground = Brushes.White, FontSize = 18, TextAlignment = TextAlignment.Center,
            };
            Canvas.SetLeft(hint, Width / 2 - 200);
            Canvas.SetTop(hint, Height / 2 - 30);
            canvas.Children.Add(hint);
            return;
        }

        foreach (var r in regions)
        {
            var rect = new Rect(r.X * Width, r.Y * Height, r.Width * Width, r.Height * Height);
            var shape = new Rectangle
            {
                Width = rect.Width, Height = rect.Height,
                Stroke = Brushes.White, StrokeThickness = 2,
                Fill = new SolidColorBrush(Color.FromArgb(120, 80, 160, 255)),
                Cursor = Cursors.Hand,
            };
            Canvas.SetLeft(shape, rect.X); Canvas.SetTop(shape, rect.Y);
            shape.MouseLeftButtonDown += (_, _) =>
            {
                // Convert WPF rect (DIPs) back to device pixels for SetWindowPos.
                var screenLeft = _screen.Bounds.X + rect.X;
                var screenTop  = _screen.Bounds.Y + rect.Y;
                var picked = new Region
                {
                    DisplayKey = _screen.Key,
                    X = r.X, Y = r.Y, Width = r.Width, Height = r.Height,
                    PixelRect = new Rect(screenLeft, screenTop, rect.Width, rect.Height),
                };
                Close();
                // Allow the previously-focused window to come back before moving.
                Dispatcher.BeginInvoke(new Action(() => _onPicked(picked)),
                                       System.Windows.Threading.DispatcherPriority.Background);
            };
            canvas.Children.Add(shape);
        }
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) Close();
    }
}
