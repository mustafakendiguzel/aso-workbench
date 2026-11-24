using System.Collections.ObjectModel;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace AsoDesktop.Core.ViewModels;

/// <summary>A storefront in a checkbox list.</summary>
public sealed partial class SelectableStorefront(StorefrontInfo storefront) : ObservableObject
{
    public StorefrontInfo Storefront { get; } = storefront;
    public string Title => Storefront.Title;

    [ObservableProperty] public partial bool IsSelected { get; set; }
}

/// <summary>The Add App dialog: find the app by name, link or ID, then choose the device and the markets to track.</summary>
public sealed partial class AddAppViewModel : ObservableObject
{
    private readonly AsoClient client;
    private readonly StatusViewModel status;

    public AddAppViewModel(AsoClient client, StatusViewModel status, IReadOnlyList<StorefrontInfo> storefronts, string defaultCountry = "US")
    {
        this.client = client;
        this.status = status;
        Storefronts = storefronts;
        Countries = storefronts.Select(s => new SelectableStorefront(s) { IsSelected = s.Code == defaultCountry }).ToList();
        foreach (var country in Countries) country.PropertyChanged += (_, _) => AddCommand.NotifyCanExecuteChanged();
        SearchCountry = storefronts.FirstOrDefault(s => s.Code == defaultCountry) ?? (storefronts.Count > 0 ? storefronts[0] : null);
    }

    public IReadOnlyList<StorefrontInfo> Storefronts { get; }
    public IReadOnlyList<SelectableStorefront> Countries { get; }
    public static IReadOnlyList<string> Devices => KeywordsViewModel.Devices;
    public ObservableCollection<SearchResultApp> Results { get; } = [];

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(SearchCommand))]
    public partial string Query { get; set; } = "";

    [ObservableProperty] public partial StorefrontInfo? SearchCountry { get; set; }

    [ObservableProperty]
    [NotifyCanExecuteChangedFor(nameof(AddCommand))]
    public partial SearchResultApp? SelectedResult { get; set; }

    [ObservableProperty] public partial string Device { get; set; } = "iphone";

    /// <summary>Set when the app was added; the dialog closes on it.</summary>
    [ObservableProperty] public partial AppRecord? Added { get; set; }

    public IEnumerable<string> SelectedCountries => Countries.Where(c => c.IsSelected).Select(c => c.Storefront.Code);

    private bool CanSearch() => !string.IsNullOrWhiteSpace(Query);

    [RelayCommand(CanExecute = nameof(CanSearch))]
    private Task SearchAsync() => status.RunAsync("Searching the App Store…", async () =>
    {
        var results = await client.FindAppsAsync(Query.Trim(), SearchCountry?.Code ?? "US").ConfigureAwait(true);
        Results.Clear();
        foreach (var result in results) Results.Add(result);
        SelectedResult = Results.FirstOrDefault();
        status.Info(results.Count == 0 ? "No apps found." : $"{results.Count} app(s) found.");
    });

    private bool CanAdd() => SelectedResult is not null && SelectedCountries.Any();

    [RelayCommand(CanExecute = nameof(CanAdd))]
    private Task AddAsync() => SelectedResult is not { } app ? Task.CompletedTask : status.RunAsync($"Adding {app.Name}…", async () =>
    {
        var markets = SelectedCountries.ToList();
        Added = await client.AddAppAsync(app.TrackId.ToString(System.Globalization.CultureInfo.InvariantCulture), SearchCountry?.Code, markets, Device)
            .ConfigureAwait(true);
        status.Info($"Tracking {Added.Name} in {string.Join(", ", markets)}.");
    });
}
