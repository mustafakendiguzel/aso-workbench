namespace AsoDesktop.Core.ViewModels;

/// <summary>What a key unlocks, where its data goes and how to get it, shown above the key fields.</summary>
public sealed record ConnectionGuide(string Need, IReadOnlyList<string> Unlocks, string DataFlow, IReadOnlyList<string> Steps, string? LinkTitle, string? Link)
{
    /// <summary>What this version of the window does with the key today.</summary>
    public string Availability { get; init; } = NotYetUsed;

    public const string NotYetUsed = "This version stores and tests the key. The features above come to Windows and Linux in later versions; until then they need the macOS app.";
}

/// <summary>
/// The macOS app's connection guides, worded for Windows and Linux (no Terminal-only steps, "this computer").
/// Features the engine does not use yet are marked, so nobody stores a key expecting more than it does.
/// </summary>
public static class ConnectionGuides
{
    public static ConnectionGuide AppleAds { get; } = new(
        Need: "Recommended",
        Unlocks:
        [
            "Apple's own search popularity (1–100) per country, from the monthly Search Term Rank lists",
            "Your campaigns' results per keyword and country: impressions, taps, installs, spend",
            "Popularity when trying your keywords in other countries",
        ],
        DataFlow: "Read-only. Signs a token on this computer and talks only to appleid.apple.com, api.ads.apple.com and api.searchads.apple.com. Needs no campaign and spends no money.",
        Steps:
        [
            "Create a key pair; the private key never leaves this computer. With OpenSSL (included with Git for Windows and most Linux systems): openssl ecparam -genkey -name prime256v1 -noout -out aso-ads-private.pem, then openssl ec -in aso-ads-private.pem -pubout -out aso-ads-public.pem",
            "ads.apple.com → Account Settings → User Management: invite an API user with the API Account Read Only role (or use an account that already has API access).",
            "Signed in as that user: Account Settings → API → paste the contents of aso-ads-public.pem → Save. Apple shows the Client ID and Key ID.",
            "The Org ID is in the account menu at the top right of ads.apple.com.",
            "Here: fill Client ID, Key ID and Org ID, choose aso-ads-private.pem, press Save, then Test connection.",
        ],
        LinkTitle: "Open Apple Ads",
        Link: "https://app-ads.apple.com/cm/app")
    {
        Availability = "This version reads popularity with the key (Keywords tab, and after every measurement) and your campaign results (Overview). Other "
                       + "countries come to Windows and Linux in later versions; until then they need the macOS app.",
    };

    public static ConnectionGuide AppStoreConnect { get; } = new(
        Need: "Optional",
        Unlocks:
        [
            "Pull your current listing (name, subtitle, keywords, description, What's New) for every language",
            "Publish drafts back: missing languages are created, screenshots copied, the result re-read",
            "Detect new releases and read the privacy policy URL for the legal footer",
        ],
        DataFlow: "Signs a short-lived token on this computer and talks only to api.appstoreconnect.apple.com. Nothing is written until you press Apply and confirm; nothing is ever submitted for review.",
        Steps:
        [
            "Open App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys.",
            "Generate a key with the App Manager role (needed to write metadata; Developer is enough for read-only).",
            "Download the .p8 file (Apple lets you download it only once) and copy the Issuer ID shown above the table.",
            "Here: fill the Issuer ID, choose the .p8 file (the Key ID is read from its name, AuthKey_<KEYID>.p8), press Save.",
        ],
        LinkTitle: "Open App Store Connect",
        Link: "https://appstoreconnect.apple.com/access/integrations/api");

    public static ConnectionGuide OpenRouter { get; } = new(
        Need: "Optional",
        Unlocks:
        [
            "AI metadata writer, Make better, Write all locales and What's New translations",
            "Local-language keyword ideas when trying keywords in other countries",
            "Brand, relevance and \"is this an app?\" checks behind Golden keywords and Fit",
        ],
        DataFlow: "Pay-as-you-go on your own OpenRouter account. Sends keyword text, your app's public name and description and your drafts to openrouter.ai, never your keys or data file.",
        Steps:
        [
            "Create an account at openrouter.ai and add a little credit.",
            "Keys → Create key; optionally set a spending limit on the key.",
            "Paste the key (starts with sk-or-v1-) here and press Save.",
        ],
        LinkTitle: "Open OpenRouter keys",
        Link: "https://openrouter.ai/settings/keys")
    {
        Availability = "This version uses the key for the brand, naturalness and fit checks in Find keywords. The writer and the other "
                       + "checks come to Windows and Linux in later versions; until then they need the macOS app.",
    };

    public static ConnectionGuide RevenueCat { get; } = new(
        Need: "Optional",
        Unlocks: ["MRR, active subscriptions, 28-day revenue, new customers and trials on Overview, with daily history"],
        DataFlow: "Read-only. Talks only to api.revenuecat.com. Apps are matched to projects by bundle ID.",
        Steps:
        [
            "RevenueCat → your project → Project settings → API keys → + New secret API key.",
            "Choose API version 2 and give it read-only permissions.",
            "Paste it here, one key per line (one per project), and press Save.",
        ],
        LinkTitle: "Open RevenueCat",
        Link: "https://app.revenuecat.com")
    {
        Availability = "This version reads revenue with the keys: the Revenue card on the Overview, at start-up and on Refresh.",
    };
}
