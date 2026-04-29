using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows;

namespace MW;

public sealed class Region
{
    [JsonPropertyName("displayKey")] public string DisplayKey { get; set; } = "";
    [JsonPropertyName("x")]      public double X { get; set; }
    [JsonPropertyName("y")]      public double Y { get; set; }
    [JsonPropertyName("width")]  public double Width { get; set; }
    [JsonPropertyName("height")] public double Height { get; set; }

    /// <summary>Pixel rect on the matching screen, in virtual-screen coordinates.</summary>
    [JsonIgnore]
    public Rect PixelRect { get; set; }
}

public sealed class RegionStore
{
    private readonly Dictionary<string, List<Region>> _byDisplay = new();
    private static readonly string DataDir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                     "mikkelsworkspace");
    private static string DataFile => Path.Combine(DataDir, "regions.json");

    public IReadOnlyList<Region> Regions(string displayKey) =>
        _byDisplay.TryGetValue(displayKey, out var list) ? list : Array.Empty<Region>();

    public void SetRegions(string displayKey, IEnumerable<Region> regions)
    {
        var list = regions.Select(r => { r.DisplayKey = displayKey; return r; }).ToList();
        if (list.Count == 0) _byDisplay.Remove(displayKey);
        else                 _byDisplay[displayKey] = list;
        Save();
    }

    public void Load()
    {
        try
        {
            if (!File.Exists(DataFile)) return;
            var json = File.ReadAllText(DataFile);
            var raw = JsonSerializer.Deserialize<List<Region>>(json) ?? new();
            _byDisplay.Clear();
            foreach (var g in raw.GroupBy(r => r.DisplayKey))
                _byDisplay[g.Key] = g.ToList();
        }
        catch { /* ignore corrupt store */ }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(DataDir);
            var flat = _byDisplay.SelectMany(kv => kv.Value).ToList();
            var json = JsonSerializer.Serialize(flat,
                new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(DataFile, json);
        }
        catch { /* ignore IO errors */ }
    }
}
