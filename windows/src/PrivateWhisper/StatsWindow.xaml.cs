using System.Text;
using System.Windows;

namespace PrivateWhisper;

/// <summary>Read-only display of the aggregate counters in StatsStore.</summary>
public partial class StatsWindow : Window
{
    public StatsWindow()
    {
        InitializeComponent();
        Populate();
    }

    private void Populate()
    {
        DictationStats stats = StatsStore.Shared.Stats;

        DictationsText.Text = stats.TotalDictations.ToString();
        WordsText.Text = stats.TotalWords.ToString();
        AudioText.Text = FormatDuration(stats.TotalAudioSeconds);
        LatencyText.Text = $"{stats.AverageLatency:F1} s";
        FallbacksText.Text = stats.CleanupFallbacks.ToString();

        string today = DateTime.Now.ToString("yyyy-MM-dd");
        stats.ByDay.TryGetValue(today, out int todayCount);
        TodayText.Text = todayCount.ToString();

        if (stats.ByLanguage.Count == 0)
        {
            LanguagesText.Text = "—";
        }
        else
        {
            LanguagesText.Text = string.Join("   ",
                stats.ByLanguage.OrderByDescending(kv => kv.Value)
                    .Select(kv => $"{kv.Key}: {kv.Value}"));
        }

        var lastDays = new StringBuilder();
        for (int i = 6; i >= 0; i--)
        {
            string day = DateTime.Now.AddDays(-i).ToString("yyyy-MM-dd");
            stats.ByDay.TryGetValue(day, out int count);
            lastDays.AppendLine($"{day}  {count,4}");
        }
        LastDaysText.Text = lastDays.ToString().TrimEnd();
    }

    private static string FormatDuration(double seconds)
    {
        if (seconds < 60) return $"{seconds:F0} s";
        if (seconds < 3600) return $"{seconds / 60:F1} min";
        return $"{seconds / 3600:F1} h";
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
