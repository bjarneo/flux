using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace Flux;

// A view that draws itself from the models, as a SwiftUI view does. A change
// of a model that it watches, or of the theme, draws it again on the next
// turn of the UI thread. Fields, lists, and scroll views that must keep their
// state live in fields and go into each new drawing.
public abstract class View : ContentControl
{
    readonly List<INotifyPropertyChanged> watched = [];
    bool pending;
    bool live;

    protected View()
    {
        Focusable = false;
        Loaded += (_, _) =>
        {
            live = true;
            foreach (var m in watched)
            {
                m.PropertyChanged += OnModelChanged;
            }
            Tn.Changed += Invalidate;
            Invalidate();
        };
        Unloaded += (_, _) =>
        {
            live = false;
            foreach (var m in watched)
            {
                m.PropertyChanged -= OnModelChanged;
            }
            Tn.Changed -= Invalidate;
        };
    }

    // Draws the view again when the model changes.
    protected void Watch(INotifyPropertyChanged? model)
    {
        if (model is null || watched.Contains(model))
        {
            return;
        }
        watched.Add(model);
        if (live)
        {
            model.PropertyChanged += OnModelChanged;
        }
    }

    void OnModelChanged(object? sender, PropertyChangedEventArgs e) => Invalidate();

    // While true, the view does not draw again, for example during a drag of
    // a slider in it. The end of the hold draws the changes that came.
    protected bool Hold
    {
        get => hold;
        set
        {
            hold = value;
            if (!value && missed)
            {
                missed = false;
                Invalidate();
            }
        }
    }

    bool hold;
    bool missed;

    // Draws the view on the next turn of the UI thread. More changes in the
    // same turn give 1 drawing.
    public void Invalidate()
    {
        if (hold)
        {
            missed = true;
            return;
        }
        if (pending)
        {
            return;
        }
        pending = true;
        Dispatcher.BeginInvoke(DispatcherPriority.Background, () =>
        {
            pending = false;
            Redraw();
        });
    }

    // Draws the view now. Tests call it.
    public void Redraw()
    {
        var next = Build();
        // A view with a fixed layout returns the same element. It keeps its
        // parent, so that a field in it keeps the focus.
        if (!ReferenceEquals(next, Content))
        {
            Ui.Detach(next);
            Content = next;
        }
        Redrawn();
    }

    protected abstract UIElement Build();

    // Called after each drawing.
    protected virtual void Redrawn()
    {
    }
}

// A page of a destination or a route. The window shows its title, its
// context line, and the scope menu on a destination root, unless the page
// draws its own top bar.
public abstract class Page : View
{
    protected AppModel Model { get; }

    protected Page(AppModel model)
    {
        Model = model;
        Watch(model);
    }

    public abstract string Title { get; }
    public virtual string Subtitle => "";

    // True when the page draws its own top bar, as a chat does. The window
    // then shows no header over the page.
    public virtual bool OwnHeader => false;

    // Called when the title or the context line changed after a drawing.
    public event Action? HeaderChanged;

    string shownTitle = "";
    string shownSubtitle = "";

    protected override void Redrawn()
    {
        if (Title == shownTitle && Subtitle == shownSubtitle)
        {
            return;
        }
        shownTitle = Title;
        shownSubtitle = Subtitle;
        HeaderChanged?.Invoke();
    }
}
