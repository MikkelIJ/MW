using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Shapes;

namespace MW;

public partial class EditorWindow : Window
{
    private readonly RegionStore _store;
    private readonly ScreenInfo _screen;
    private readonly List<Rectangle> _shapes = new();
    private Point? _dragStart;
    private Rectangle? _dragShape;

    public EditorWindow(RegionStore store, IReadOnlyList<ScreenInfo> screens)
    {
        InitializeComponent();
        _store = store;
        // For v1 we edit the screen the cursor is on (or primary).
        _screen = screens.FirstOrDefault(s => s.IsPrimary) ?? screens[0];
        Left = _screen.Bounds.X; Top = _screen.Bounds.Y;
        Width = _screen.Bounds.Width; Height = _screen.Bounds.Height;
        Loaded += (_, _) =>
        {
            foreach (var r in _store.Regions(_screen.Key))
                AddShape(new Rect(
                    r.X * Width, r.Y * Height, r.Width * Width, r.Height * Height));
        };
    }

    private Rectangle AddShape(Rect rect)
    {
        var shape = new Rectangle
        {
            Width = rect.Width, Height = rect.Height,
            Stroke = Brushes.White, StrokeThickness = 2,
            Fill = new SolidColorBrush(Color.FromArgb(80, 80, 160, 255)),
        };
        Canvas.SetLeft(shape, rect.X); Canvas.SetTop(shape, rect.Y);
        shape.MouseLeftButtonDown += (_, e) =>
        {
            if (Keyboard.Modifiers == ModifierKeys.None)
            {
                canvas.Children.Remove(shape); _shapes.Remove(shape); e.Handled = true;
            }
        };
        canvas.Children.Add(shape);
        _shapes.Add(shape);
        return shape;
    }

    private void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is Rectangle) return;
        _dragStart = e.GetPosition(canvas);
        _dragShape = AddShape(new Rect(_dragStart.Value, new Size(1, 1)));
    }

    private void OnMouseMove(object sender, MouseEventArgs e)
    {
        if (_dragStart is null || _dragShape is null) return;
        var p = e.GetPosition(canvas);
        var x = Math.Min(p.X, _dragStart.Value.X);
        var y = Math.Min(p.Y, _dragStart.Value.Y);
        var w = Math.Abs(p.X - _dragStart.Value.X);
        var h = Math.Abs(p.Y - _dragStart.Value.Y);
        Canvas.SetLeft(_dragShape, x); Canvas.SetTop(_dragShape, y);
        _dragShape.Width = w; _dragShape.Height = h;
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (_dragShape is { Width: < 12 } or { Height: < 12 })
        {
            canvas.Children.Remove(_dragShape!); _shapes.Remove(_dragShape!);
        }
        _dragStart = null; _dragShape = null;
    }

    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { Close(); return; }
        if (e.Key == Key.Enter)
        {
            var regions = _shapes.Select(s => new Region
            {
                X = Canvas.GetLeft(s) / Width,
                Y = Canvas.GetTop(s)  / Height,
                Width  = s.Width  / Width,
                Height = s.Height / Height,
            });
            _store.SetRegions(_screen.Key, regions);
            Close();
        }
    }
}
