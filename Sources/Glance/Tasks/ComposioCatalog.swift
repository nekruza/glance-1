import Foundation

/// Static, offline catalog of popular Composio apps the user can connect.
///
/// Connecting happens on the Composio dashboard (deep-linked per app), so this
/// list only needs to power in-app search + discovery. A live catalog query
/// would mean a multi-second `claude -p` subprocess per keystroke — this list
/// is instant. Slugs match Composio toolkit slugs (lowercase, no spaces).
enum ComposioCatalog {

    struct App: Identifiable, Hashable {
        let slug: String
        let name: String
        let category: String
        var id: String { slug }
    }

    /// Composio dashboard page for one app. Falls back to the dashboard root
    /// if the app page 404s — harmless, the user still lands on Composio.
    static func dashboardURL(for slug: String) -> URL {
        URL(string: "https://dashboard.composio.dev/apps/\(slug)")
            ?? URL(string: "https://dashboard.composio.dev/")!
    }

    /// Case-insensitive substring match over name, slug, and category. Empty
    /// query → all.
    static func search(_ query: String) -> [App] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(q)
            || $0.slug.contains(q)
            || $0.category.lowercased().contains(q)
        }
    }

    /// Curated set of ~60 widely-used Composio toolkits, alphabetical by name.
    static let all: [App] = [
        App(slug: "activecampaign", name: "ActiveCampaign", category: "Marketing"),
        App(slug: "airtable", name: "Airtable", category: "Database"),
        App(slug: "asana", name: "Asana", category: "Project management"),
        App(slug: "attio", name: "Attio", category: "CRM"),
        App(slug: "bitbucket", name: "Bitbucket", category: "Developer"),
        App(slug: "cal", name: "Cal.com", category: "Scheduling"),
        App(slug: "calendly", name: "Calendly", category: "Scheduling"),
        App(slug: "canva", name: "Canva", category: "Design"),
        App(slug: "clickup", name: "ClickUp", category: "Project management"),
        App(slug: "confluence", name: "Confluence", category: "Docs"),
        App(slug: "discord", name: "Discord", category: "Communication"),
        App(slug: "docusign", name: "DocuSign", category: "Signing"),
        App(slug: "dropbox", name: "Dropbox", category: "Storage"),
        App(slug: "figma", name: "Figma", category: "Design"),
        App(slug: "freshdesk", name: "Freshdesk", category: "Support"),
        App(slug: "front", name: "Front", category: "Support"),
        App(slug: "github", name: "GitHub", category: "Developer"),
        App(slug: "gitlab", name: "GitLab", category: "Developer"),
        App(slug: "gmail", name: "Gmail", category: "Email"),
        App(slug: "googlecalendar", name: "Google Calendar", category: "Calendar"),
        App(slug: "googledocs", name: "Google Docs", category: "Docs"),
        App(slug: "googledrive", name: "Google Drive", category: "Storage"),
        App(slug: "googlemeet", name: "Google Meet", category: "Communication"),
        App(slug: "googlesheets", name: "Google Sheets", category: "Spreadsheets"),
        App(slug: "googletasks", name: "Google Tasks", category: "Productivity"),
        App(slug: "granola", name: "Granola", category: "Meetings"),
        App(slug: "hubspot", name: "HubSpot", category: "CRM"),
        App(slug: "intercom", name: "Intercom", category: "Support"),
        App(slug: "jira", name: "Jira", category: "Project management"),
        App(slug: "klaviyo", name: "Klaviyo", category: "Marketing"),
        App(slug: "linear", name: "Linear", category: "Project management"),
        App(slug: "linkedin", name: "LinkedIn", category: "Social"),
        App(slug: "mailchimp", name: "Mailchimp", category: "Marketing"),
        App(slug: "microsoft_teams", name: "Microsoft Teams", category: "Communication"),
        App(slug: "miro", name: "Miro", category: "Whiteboard"),
        App(slug: "monday", name: "monday.com", category: "Project management"),
        App(slug: "notion", name: "Notion", category: "Docs"),
        App(slug: "onedrive", name: "OneDrive", category: "Storage"),
        App(slug: "outlook", name: "Outlook", category: "Email"),
        App(slug: "pagerduty", name: "PagerDuty", category: "DevOps"),
        App(slug: "pipedrive", name: "Pipedrive", category: "CRM"),
        App(slug: "posthog", name: "PostHog", category: "Analytics"),
        App(slug: "quickbooks", name: "QuickBooks", category: "Finance"),
        App(slug: "reddit", name: "Reddit", category: "Social"),
        App(slug: "salesforce", name: "Salesforce", category: "CRM"),
        App(slug: "sentry", name: "Sentry", category: "DevOps"),
        App(slug: "servicenow", name: "ServiceNow", category: "ITSM"),
        App(slug: "sharepoint", name: "SharePoint", category: "Storage"),
        App(slug: "shopify", name: "Shopify", category: "E-commerce"),
        App(slug: "slack", name: "Slack", category: "Communication"),
        App(slug: "snowflake", name: "Snowflake", category: "Data"),
        App(slug: "stripe", name: "Stripe", category: "Payments"),
        App(slug: "supabase", name: "Supabase", category: "Developer"),
        App(slug: "trello", name: "Trello", category: "Project management"),
        App(slug: "twilio", name: "Twilio", category: "Communication"),
        App(slug: "twitter", name: "Twitter / X", category: "Social"),
        App(slug: "typeform", name: "Typeform", category: "Forms"),
        App(slug: "whatsapp", name: "WhatsApp", category: "Communication"),
        App(slug: "youtube", name: "YouTube", category: "Video"),
        App(slug: "zendesk", name: "Zendesk", category: "Support"),
        App(slug: "zoho", name: "Zoho", category: "CRM"),
        App(slug: "zoom", name: "Zoom", category: "Communication"),
    ]
}
