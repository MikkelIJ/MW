using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;

namespace MW;

internal static class UpdateChecker
{
    public const string Repo = "MikkelIJ/MW";

    public static string CurrentVersion =>
        Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "0";

    public static async Task CheckAsync(bool showWhenUpToDate)
    {
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.UserAgent.ParseAdd("MW-app");
            http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
            var json = await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases/latest");
            var rel = JsonSerializer.Deserialize<Release>(json);
            if (rel is null) return;
            var newer = Compare(CurrentVersion, rel.tag_name) < 0;
            if (newer)
            {
                Application.Current.Dispatcher.Invoke(() =>
                {
                    var res = MessageBox.Show(
                        $"MW {rel.tag_name} is available (you're on {CurrentVersion}).\n\n" +
                        "Open the release page?",
                        "Update available", MessageBoxButton.YesNo, MessageBoxImage.Information);
                    if (res == MessageBoxResult.Yes)
                        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(rel.html_url)
                        { UseShellExecute = true });
                });
            }
            else if (showWhenUpToDate)
            {
                Application.Current.Dispatcher.Invoke(() =>
                    MessageBox.Show($"MW is up to date (you're on {CurrentVersion}; latest is {rel.tag_name}).",
                        "MW", MessageBoxButton.OK, MessageBoxImage.Information));
            }
        }
        catch (Exception ex) when (showWhenUpToDate)
        {
            Application.Current.Dispatcher.Invoke(() =>
                MessageBox.Show("Couldn't check for updates: " + ex.Message,
                    "MW", MessageBoxButton.OK, MessageBoxImage.Warning));
        }
        catch { /* silent on background check */ }
    }

    private static int Compare(string a, string b)
    {
        static int[] Parse(string s)
        {
            if (s.StartsWith("v")) s = s[1..];
            var parts = s.Split('.');
            var arr = new int[parts.Length];
            for (int i = 0; i < parts.Length; i++) int.TryParse(parts[i], out arr[i]);
            return arr;
        }
        var ax = Parse(a); var bx = Parse(b);
        for (int i = 0; i < Math.Max(ax.Length, bx.Length); i++)
        {
            var av = i < ax.Length ? ax[i] : 0;
            var bv = i < bx.Length ? bx[i] : 0;
            if (av != bv) return av < bv ? -1 : 1;
        }
        return 0;
    }

    private sealed class Release
    {
        public string tag_name { get; set; } = "";
        public string html_url { get; set; } = "";
    }
}
