using System.Runtime.InteropServices;
using System.Windows.Threading;
using FluxKit;
using Windows.Globalization;
using Windows.Media.SpeechRecognition;

namespace Flux;

// Dictation with the speech recognizer of Windows. A session listens until
// the user stops it, and each final text goes to the field at its cursor,
// see DictationText. The words that the recognizer still revises show in
// Partial. Windows needs online speech recognition for dictation, so a
// computer with that privacy setting off gets SpeechDenied. Dictation.swift
// of the Mac app has the same job.
public sealed class Dictation : Model
{
    // What the dictation does now.
    public enum Phase
    {
        Idle,
        Starting,
        Listening,
        Stopping,
    }

    // The message when the speech privacy setting of Windows is off.
    public const string SpeechDenied = "Turn on Online speech recognition in Settings > Privacy & security > Speech to dictate";

    // The message when Windows does not let desktop apps use the microphone.
    public const string MicDenied = "Allow desktop apps in Settings > Privacy & security > Microphone to dictate";

    // The HRESULT of a recognizer whose speech privacy policy is not accepted.
    const int PrivacyPolicyNotAccepted = unchecked((int)0x80045509);

    Phase phase = Phase.Idle;
    string partial = "";
    string? error;
    bool languageError;
    string language = "";
    SpeechRecognizer? recognizer;
    Action<string>? onText;
    Dispatcher? ui;
    DateTimeOffset started;
    // Counts the starts and the cancels, so that a start that ends after a cancel stops.
    int run;

    public Phase State
    {
        get => phase;
        private set => Set(ref phase, value);
    }

    // The words that the recognizer heard and may still change.
    public string Partial
    {
        get => partial;
        private set => Set(ref partial, value);
    }

    // Why the last dictation failed, or null.
    public string? Error
    {
        get => error;
        private set => Set(ref error, value);
    }

    // True when Error is about the language, so that the user can choose another one.
    public bool LanguageError
    {
        get => languageError;
        private set => Set(ref languageError, value);
    }

    // The tag of the language of the last dictation, such as en-US. It is
    // empty for Automatic until the recognizer starts.
    public string LanguageTag
    {
        get => language;
        private set => Set(ref language, value);
    }

    // The time of the dictation, such as 0:07.
    public string Clock => DictationText.Clock((DateTimeOffset.Now - started).TotalSeconds);

    // The languages that the recognizer of this computer writes, as tags.
    public static IReadOnlyList<string> Languages()
    {
        try
        {
            return DictationText.Languages(SpeechRecognizer.SupportedTopicLanguages.Select(l => l.LanguageTag));
        }
        catch (COMException)
        {
            return [];
        }
    }

    // The speech language of Windows as a tag, or empty when Windows has
    // none. A dictation in Automatic uses it.
    public static string SystemLanguage()
    {
        try
        {
            return SpeechRecognizer.SystemSpeechLanguage?.LanguageTag ?? "";
        }
        catch (COMException)
        {
            return "";
        }
    }

    // Starts a dictation in the language tag, or in the speech language of
    // Windows when the tag is empty. onText gets each final text.
    public void Start(string language, Action<string> text)
    {
        if (State != Phase.Idle)
        {
            return;
        }
        ui = Dispatcher.CurrentDispatcher;
        onText = text;
        Error = null;
        LanguageError = false;
        Partial = "";
        // The tag that the user chose, until the recognizer tells its own.
        LanguageTag = language;
        State = Phase.Starting;
        _ = StartAsync(language, ++run);
    }

    async Task StartAsync(string language, int my)
    {
        SpeechRecognizer? r = null;
        try
        {
            Language? lang = null;
            if (language.Length > 0)
            {
                if (!Language.IsWellFormed(language))
                {
                    Fail(DictationText.NotSupported(language), true);
                    return;
                }
                lang = new Language(language);
            }
            r = lang is null ? new SpeechRecognizer() : new SpeechRecognizer(lang);
            var compiled = await r.CompileConstraintsAsync();
            if (my != run)
            {
                r.Dispose();
                return;
            }
            var tag = r.CurrentLanguage.LanguageTag;
            LanguageTag = tag;
            if (compiled.Status != SpeechRecognitionResultStatus.Success)
            {
                r.Dispose();
                Fail(Message(compiled.Status, tag), compiled.Status == SpeechRecognitionResultStatus.TopicLanguageNotSupported);
                return;
            }
            r.HypothesisGenerated += (_, e) => Post(() => Partial = e.Hypothesis.Text);
            r.ContinuousRecognitionSession.ResultGenerated += (_, e) =>
            {
                var said = e.Result.Text;
                if (e.Result.Status == SpeechRecognitionResultStatus.Success && said.Trim().Length > 0)
                {
                    Post(() =>
                    {
                        Partial = "";
                        onText?.Invoke(said);
                    });
                }
            };
            var session = r;
            r.ContinuousRecognitionSession.Completed += (_, e) => Post(() =>
            {
                // A cancel ended this session already.
                if (recognizer != session)
                {
                    return;
                }
                if (e.Status is not (SpeechRecognitionResultStatus.Success or SpeechRecognitionResultStatus.UserCanceled
                    or SpeechRecognitionResultStatus.TimeoutExceeded))
                {
                    Error = Message(e.Status, tag);
                }
                End();
            });
            recognizer = r;
            await r.ContinuousRecognitionSession.StartAsync();
            if (my != run)
            {
                return;
            }
            started = DateTimeOffset.Now;
            State = Phase.Listening;
        }
        catch (UnauthorizedAccessException)
        {
            r?.Dispose();
            Fail(MicDenied);
        }
        catch (Exception e) when (e.HResult == PrivacyPolicyNotAccepted)
        {
            r?.Dispose();
            Fail(SpeechDenied);
        }
        catch (Exception e) when (e is COMException or ArgumentException or InvalidOperationException)
        {
            r?.Dispose();
            FluxLog.Error("app", $"dictation did not start: {e.Message}");
            Fail("Dictation did not start. Try again.");
        }
    }

    // Stops the dictation. The words that the recognizer heard still go to the field.
    public void Stop()
    {
        if (recognizer is not { } r || State != Phase.Listening)
        {
            return;
        }
        State = Phase.Stopping;
        _ = StopAsync(r);
    }

    static async Task StopAsync(SpeechRecognizer r)
    {
        try
        {
            await r.ContinuousRecognitionSession.StopAsync();
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            FluxLog.Error("app", $"dictation did not stop: {e.Message}");
        }
    }

    // Ends the dictation at once. The words that are not final go away.
    public void Cancel()
    {
        run++;
        onText = null;
        if (recognizer is { } r)
        {
            _ = CancelAsync(r);
        }
        End();
    }

    static async Task CancelAsync(SpeechRecognizer r)
    {
        try
        {
            await r.ContinuousRecognitionSession.CancelAsync();
        }
        catch (Exception e) when (e is COMException or InvalidOperationException)
        {
            FluxLog.Error("app", $"dictation did not cancel: {e.Message}");
        }
    }

    void End()
    {
        recognizer?.Dispose();
        recognizer = null;
        Partial = "";
        State = Phase.Idle;
    }

    void Fail(string message, bool language = false)
    {
        Error = message;
        LanguageError = language;
        State = Phase.Idle;
    }

    void Post(Action action) => ui?.BeginInvoke(action);

    // The message for a status of the recognizer.
    static string Message(SpeechRecognitionResultStatus status, string tag) => status switch
    {
        SpeechRecognitionResultStatus.TopicLanguageNotSupported or SpeechRecognitionResultStatus.GrammarLanguageMismatch => DictationText.NotSupported(tag),
        SpeechRecognitionResultStatus.MicrophoneUnavailable => DictationText.NoMicrophone,
        SpeechRecognitionResultStatus.NetworkFailure => "The speech service of Windows is not reachable. Check the network, then try again.",
        SpeechRecognitionResultStatus.AudioQualityFailure => "The microphone sound is too weak or too loud. Try again.",
        _ => "Dictation stopped. Try again.",
    };
}
