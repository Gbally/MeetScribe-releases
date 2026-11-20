using NAudio.CoreAudioApi;

namespace Hesper;

/// The few settings of the preview: name, notes folder, languages, to-do check, devices.
sealed class SettingsForm : Form
{
    readonly AppSettings settings;
    readonly TextBox name = new() { Width = 300 };
    readonly TextBox folder = new() { Width = 300 };
    readonly TextBox languages = new() { Width = 300, PlaceholderText = "empty: detected (e.g. en, or en,fr)" };
    readonly ComboBox filter = new() { Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
    readonly ComboBox mic = new() { Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
    readonly ComboBox speakers = new() { Width = 300, DropDownStyle = ComboBoxStyle.DropDownList };
    const string Default = "Windows default";
    static readonly (string Value, string Label)[] Filters =
        [("off", "Off: list every to-do found"), ("standard", "Standard: check each to-do once more"), ("strict", "Strict: keep only clear to-dos")];

    public SettingsForm(AppSettings settings)
    {
        this.settings = settings;
        Text = "Hesper settings";
        Icon = Brand.Icon(32);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(12);

        name.Text = settings.MyName;
        folder.Text = settings.NotesFolder;
        languages.Text = settings.Languages;
        filter.Items.AddRange(Filters.Select(f => f.Label).ToArray());
        filter.SelectedIndex = Math.Max(0, Array.FindIndex(Filters, f => f.Value == settings.TodoFilter));
        Fill(mic, Recorder.DeviceNames(DataFlow.Capture), settings.Microphone);
        Fill(speakers, Recorder.DeviceNames(DataFlow.Render), settings.Speakers);

        var browse = new Button { Text = "Choose…", AutoSize = true };
        browse.Click += (_, _) =>
        {
            using var d = new FolderBrowserDialog { SelectedPath = folder.Text, UseDescriptionForTitle = true, Description = "Notes folder" };
            if (d.ShowDialog(this) == DialogResult.OK) folder.Text = d.SelectedPath;
        };
        var save = new Button { Text = "Save", AutoSize = true, DialogResult = DialogResult.OK };
        var cancel = new Button { Text = "Cancel", AutoSize = true, DialogResult = DialogResult.Cancel };
        save.Click += (_, _) => Save();
        AcceptButton = save;
        CancelButton = cancel;

        var grid = new TableLayoutPanel { ColumnCount = 3, AutoSize = true, Dock = DockStyle.Fill };
        void Row(string label, Control c, Control? extra = null)
        {
            grid.Controls.Add(new Label { Text = label, AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(3, 8, 12, 3) });
            grid.Controls.Add(c);
            grid.Controls.Add(extra ?? new Label { AutoSize = true });
        }
        Row("Your name", name);
        Row("Notes folder", folder, browse);
        Row("Meeting languages", languages);
        Row("To-do check", filter);
        Row("Microphone", mic);
        Row("PC sound from", speakers);
        var buttons = new FlowLayoutPanel { FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Dock = DockStyle.Fill };
        buttons.Controls.AddRange([cancel, save]);
        grid.Controls.Add(buttons);
        grid.SetColumnSpan(buttons, 3);
        Controls.Add(grid);
    }

    static void Fill(ComboBox box, List<string> names, string chosen)
    {
        box.Items.Add(Default);
        box.Items.AddRange(names.ToArray());
        box.SelectedIndex = Math.Max(0, names.IndexOf(chosen) + 1);
    }

    void Save()
    {
        settings.MyName = name.Text.Trim();
        settings.NotesFolder = folder.Text.Trim().Length > 0 ? folder.Text.Trim() : Paths.DefaultNotesFolder();
        settings.Languages = languages.Text.Trim();
        settings.TodoFilter = Filters[Math.Max(0, filter.SelectedIndex)].Value;
        settings.Microphone = mic.SelectedIndex > 0 ? (string)mic.SelectedItem! : "";
        settings.Speakers = speakers.SelectedIndex > 0 ? (string)speakers.SelectedItem! : "";
        settings.Save();
    }
}
