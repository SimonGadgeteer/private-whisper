using System.Windows;
using System.Windows.Input;

namespace PrivateWhisper;

/// <summary>Personal dictionary editor + correction-learner suggestion inbox.</summary>
public partial class DictionaryWindow : Window
{
    private readonly ConfigStore configStore;

    public DictionaryWindow(ConfigStore configStore)
    {
        this.configStore = configStore;
        InitializeComponent();
        RefreshTerms();
        RefreshSuggestions();
        SuggestionStore.Changed += OnSuggestionsChanged;
        Closed += (_, _) => SuggestionStore.Changed -= OnSuggestionsChanged;
    }

    private void OnSuggestionsChanged()
    {
        Dispatcher.BeginInvoke(RefreshSuggestions);
    }

    private void RefreshTerms()
    {
        TermsList.Items.Clear();
        foreach (string term in configStore.Config.Dictionary)
        {
            TermsList.Items.Add(term);
        }
    }

    private void RefreshSuggestions()
    {
        SuggestionsList.Items.Clear();
        foreach (string suggestion in SuggestionStore.Items)
        {
            SuggestionsList.Items.Add(suggestion);
        }
    }

    private void AddTerm(string term)
    {
        term = term.Trim();
        if (term.Length == 0) return;
        if (configStore.Config.Dictionary.Contains(term, StringComparer.OrdinalIgnoreCase)) return;
        configStore.Update(c => c.Dictionary.Add(term));
        RefreshTerms();
    }

    private void AddButton_Click(object sender, RoutedEventArgs e)
    {
        AddTerm(NewTermBox.Text);
        NewTermBox.Text = "";
        NewTermBox.Focus();
    }

    private void NewTermBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter)
        {
            AddTerm(NewTermBox.Text);
            NewTermBox.Text = "";
        }
    }

    private void RemoveButton_Click(object sender, RoutedEventArgs e)
    {
        if (TermsList.SelectedItem is string term)
        {
            configStore.Update(c => c.Dictionary.RemoveAll(
                t => string.Equals(t, term, StringComparison.Ordinal)));
            RefreshTerms();
        }
    }

    private void AcceptSuggestionButton_Click(object sender, RoutedEventArgs e)
    {
        if (SuggestionsList.SelectedItem is string suggestion)
        {
            AddTerm(suggestion);
            SuggestionStore.Remove(suggestion);
        }
    }

    private void DismissSuggestionButton_Click(object sender, RoutedEventArgs e)
    {
        if (SuggestionsList.SelectedItem is string suggestion)
        {
            SuggestionStore.Remove(suggestion);
        }
    }

    private void CloseButton_Click(object sender, RoutedEventArgs e) => Close();
}
