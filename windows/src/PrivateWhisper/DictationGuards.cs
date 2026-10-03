namespace PrivateWhisper;

/// <summary>
/// Push-to-talk on a modifier key as a pure state machine (port of the macOS HoldGesture).
/// A press becomes a dictation only after the key has been held for the hold delay with nothing
/// else pressed. Right Alt is AltGr on Swiss/German layouts (AltGr+2 is "@"), so any other key
/// while it is held means "key combination": the press is ignored, and a recording that already
/// started is cancelled and discarded.
/// </summary>
public sealed class HoldGesture
{
    public enum Phase { Up, Pending, Active, Combination }
    public enum Action { None, ScheduleActivation, CancelScheduled, Start, Stop, Cancel }

    public Phase State { get; private set; } = Phase.Up;

    public Action KeyDown()
    {
        if (State != Phase.Up) return Action.None;      // key repeat while held
        State = Phase.Pending;
        return Action.ScheduleActivation;
    }

    public Action HoldDelayElapsed()
    {
        if (State != Phase.Pending) return Action.None;
        State = Phase.Active;
        return Action.Start;
    }

    public Action KeyUp()
    {
        Phase was = State;
        State = Phase.Up;
        return was switch
        {
            Phase.Active => Action.Stop,
            Phase.Pending => Action.CancelScheduled,    // a quick tap: nothing happens
            _ => Action.None,
        };
    }

    /// <summary>Another key went down while the push-to-talk key is held. A lone modifier
    /// (Shift, Ctrl) during an ongoing dictation is tolerated.</summary>
    public Action OtherInput(bool modifierOnly)
    {
        if (State == Phase.Pending)
        {
            State = Phase.Combination;
            return Action.CancelScheduled;
        }
        if (State == Phase.Active && !modifierOnly)
        {
            State = Phase.Combination;
            return Action.Cancel;
        }
        return Action.None;
    }
}

/// <summary>
/// Speech presence for push-to-talk clips (16 kHz mono), port of the macOS VoiceActivity.
/// Counts 30 ms frames clearly louder than the clip's own background; a keystroke click spans one
/// or two frames, a short word about eight. Replaces the average-loudness gate, which let a click
/// through so Whisper echoed its prompt (the dictionary) into the text field.
/// </summary>
public static class VoiceActivity
{
    public const double FrameSeconds = 0.03;
    public const double MinVoicedSeconds = 0.15;

    public static double VoicedSeconds(float[] samples, int sampleRate = 16000)
    {
        int frame = (int)(sampleRate * FrameSeconds);
        if (frame <= 0 || samples.Length < frame) return 0;
        var levels = new List<float>(samples.Length / frame);
        for (int start = 0; start + frame <= samples.Length; start += frame)
        {
            double sum = 0;
            for (int i = start; i < start + frame; i++) sum += (double)samples[i] * samples[i];
            levels.Add((float)Math.Sqrt(sum / frame));
        }
        var sorted = levels.OrderBy(x => x).ToList();
        float background = sorted[sorted.Count / 5];                 // 20th percentile
        float threshold = Math.Max(0.006f, Math.Min(background * 3, 0.02f));
        return levels.Count(l => l > threshold) * FrameSeconds;
    }
}

/// <summary>Whisper repeats its prompt (we pass the personal dictionary) when it hears no real speech.</summary>
public static class PromptEcho
{
    /// <summary>True when the transcript is made only of dictionary words and contains at least two
    /// distinct dictionary terms. A single dictated name is still accepted.</summary>
    public static bool IsEcho(string text, IReadOnlyList<string> vocabulary)
    {
        var words = Tokens(text);
        var vocabularyWords = new HashSet<string>(vocabulary.SelectMany(Tokens));
        if (words.Count == 0 || vocabularyWords.Count == 0 || !words.All(vocabularyWords.Contains)) return false;
        var present = new HashSet<string>(words);
        int termsPresent = vocabulary.Count(term =>
        {
            var t = Tokens(term);
            return t.Count > 0 && t.All(present.Contains);
        });
        return termsPresent >= 2;
    }

    public static List<string> Tokens(string text)
    {
        var tokens = new List<string>();
        var current = new System.Text.StringBuilder();
        foreach (char c in text.ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c)) { current.Append(c); continue; }
            if (current.Length > 0) { tokens.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) tokens.Add(current.ToString());
        return tokens;
    }
}
