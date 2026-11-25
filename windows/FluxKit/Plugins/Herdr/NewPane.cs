namespace FluxKit;

// A folder where a new pane can open. Path is the folder as the computer
// sends it, often with ~/. Workspace is the first workspace in that folder,
// or null. Agents counts the agents in that workspace.
public sealed record FolderChoice(string Path, string Name, HerdrWorkspace? Workspace, int Agents)
{
    public string Id => Path;
}

// The choices of the screen that starts a herdr agent or opens a terminal,
// like NewPane.swift of the Mac app and NewPane.kt of the Android app.
public static class NewPane
{
    // The run choice for a plain terminal. Agent kinds are never empty.
    public const string ShellChoice = "";

    // Returns the folder without a slash at its end. / and ~ stay.
    public static string NormalFolder(string path)
    {
        var p = path.Trim();
        if (p.Length <= 1)
        {
            return p;
        }
        var t = p.TrimEnd('/');
        return t.Length == 0 ? "/" : t;
    }

    // An absolute folder from Get files in the form of herdr: ~ for home,
    // ~/x for a folder in it, and the absolute path for another folder.
    public static string HomeRelative(string path, string home)
    {
        var p = NormalFolder(path);
        var h = NormalFolder(home);
        if (!h.StartsWith('/') || h == "/")
        {
            return p;
        }
        if (p == h)
        {
            return "~";
        }
        if (p.StartsWith(h + "/", StringComparison.Ordinal))
        {
            return "~" + p[h.Length..];
        }
        return p;
    }

    // A folder in the form of herdr as an absolute folder for Get files, the
    // reverse of HomeRelative: home for ~, and home/x for ~/x. An absolute
    // folder stays. Null when the folder needs a home that is not known, or
    // is not a path.
    public static string? AbsoluteFolder(string folder, string home)
    {
        var f = NormalFolder(folder);
        if (f.StartsWith('/'))
        {
            return f;
        }
        var h = NormalFolder(home);
        if (!h.StartsWith('/') || h == "/")
        {
            return null;
        }
        if (f == "~")
        {
            return h;
        }
        if (f.StartsWith("~/", StringComparison.Ordinal))
        {
            return h + f[1..];
        }
        return null;
    }

    // The last part of a folder, or "home" for the home folder.
    public static string FolderName(string path)
    {
        var p = NormalFolder(path);
        return p switch
        {
            "" or "~" => "home",
            "/" => "/",
            _ => p.Split('/')[^1],
        };
    }

    // True when text is a folder path and not a search: it starts with / or ~.
    public static bool LooksLikePath(string text)
    {
        var t = text.Trim();
        return t.StartsWith('/') || t.StartsWith('~');
    }

    // The folders of the workspaces in sidebar order, each once, after the
    // home folder. A workspace without a folder is left out.
    public static IReadOnlyList<FolderChoice> FolderChoices(HerdrState state)
    {
        var homeWorkspace = WorkspaceFor(state, "~");
        var output = new List<FolderChoice>
        {
            new("~", "home", homeWorkspace, homeWorkspace is null ? 0 : state.Agents.Count(a => a.Workspace == homeWorkspace.Label)),
        };
        var seen = new HashSet<string> { "~" };
        foreach (var w in state.Workspaces)
        {
            var path = NormalFolder(w.Cwd);
            if (path.Length == 0 || !seen.Add(path))
            {
                continue;
            }
            output.Add(new FolderChoice(path, FolderName(path), w, state.Agents.Count(a => a.Workspace == w.Label)));
        }
        return output;
    }

    // The folders whose name or path has query, without regard to case. An
    // empty query keeps all.
    public static IReadOnlyList<FolderChoice> FilterFolders(IReadOnlyList<FolderChoice> folders, string query)
    {
        var q = query.Trim();
        if (q.Length == 0)
        {
            return folders;
        }
        return folders.Where(f => f.Name.Contains(q, StringComparison.CurrentCultureIgnoreCase) ||
                                  f.Path.Contains(q, StringComparison.CurrentCultureIgnoreCase)).ToArray();
    }

    // The first workspace in sidebar order whose folder is folder, or null.
    public static HerdrWorkspace? WorkspaceFor(HerdrState state, string folder)
    {
        var f = NormalFolder(folder);
        return state.Workspaces.FirstOrDefault(w => w.Cwd.Length > 0 && NormalFolder(w.Cwd) == f);
    }

    // The product name of an agent kind, or null when Flux does not know it.
    public static string? AgentProduct(string kind) => kind switch
    {
        "claude" => "Claude Code",
        "codex" => "Codex CLI",
        "opencode" => "OpenCode",
        "gemini" => "Gemini CLI",
        "copilot" => "GitHub Copilot",
        "cursor" => "Cursor Agent",
        "amp" => "Amp",
        "qwen" => "Qwen Code",
        "kimi" => "Kimi CLI",
        "muse" => "Muse Code",
        "grok" => "Grok CLI",
        "agy" => "Antigravity",
        "cline" => "Cline",
        _ => null,
    };

    // The run choice to select: last when the computer still offers it,
    // then claude, then the first agent, then a terminal. Null when the
    // computer offers nothing.
    public static string? PickRun(string? last, IReadOnlyList<string> kinds, bool shell)
    {
        if (last is not null && last != ShellChoice && kinds.Contains(last))
        {
            return last;
        }
        if (last == ShellChoice && shell)
        {
            return ShellChoice;
        }
        if (kinds.Contains("claude"))
        {
            return "claude";
        }
        if (kinds.Count > 0)
        {
            return kinds[0];
        }
        return shell ? ShellChoice : null;
    }
}
