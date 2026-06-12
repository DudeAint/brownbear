//
//  RecommendedScriptsSection.swift
//  BrownBear
//
//  The "Recommended userscripts" + "Find more userscripts" sections shown at the bottom of the
//  dashboard's Scripts tab. These run on BrownBear's own userscript engine (no manager extension
//  needed), so they belong with the userscripts — not in the Extensions tab. "Get" opens the script's
//  Greasy Fork page in BrownBear, where its Install button hands the .user.js to the engine.
//

import SwiftUI

/// A curated userscript. Tapping "Get" opens its Greasy Fork page; `id` is the stable Greasy Fork script
/// id (its page URL is stable by id) and `iconDomain` fetches a favicon for the script's main site.
struct RecommendedUserscript: Identifiable {
    let id: Int          // Greasy Fork script id
    let name: String
    let blurb: String
    let iconDomain: String

    var pageURL: URL? { URL(string: "https://greasyfork.org/en/scripts/\(id)") }
    var iconURL: URL? { URL(string: "https://www.google.com/s2/favicons?domain=\(iconDomain)&sz=64") }
}

/// A userscript repository (Greasy Fork / ScriptCat / OpenUserJS), opened in BrownBear so the in-page
/// "Install" hands a script's `.user.js` to BrownBear's userscript engine.
struct UserscriptRepoLink: Identifiable {
    let id: String
    let name: String
    let iconDomain: String
    let urlString: String

    var url: URL { URL(string: urlString) ?? URL(string: "https://greasyfork.org/en/scripts")! }
    var iconURL: URL? { URL(string: "https://www.google.com/s2/favicons?domain=\(iconDomain)&sz=64") }
}

/// The recommended-userscripts + repositories sections, dropped into the Scripts List. `installedNames`
/// hides any script the user already has (loose name match, both directions).
struct RecommendedScriptsSections: View {
    var installedNames: [String] = []

    private var available: [RecommendedUserscript] {
        Self.recommendedUserscripts.filter { rec in
            !installedNames.contains { installed in
                installed.localizedCaseInsensitiveContains(rec.name)
                    || rec.name.localizedCaseInsensitiveContains(installed)
            }
        }
    }

    var body: some View {
        if !available.isEmpty {
            Section {
                ForEach(available) { userscriptRow($0) }
            } header: {
                Text("Recommended userscripts").foregroundStyle(BBTheme.Color.textSecondary)
            } footer: {
                Text("Tap Get to open the script on Greasy Fork, then Install — BrownBear's userscript engine handles the rest.")
                    .font(.caption).foregroundStyle(BBTheme.Color.textSecondary)
            }
        }
        Section {
            ForEach(Self.repositories) { repoRow($0) }
        } header: {
            Text("Find more userscripts").foregroundStyle(BBTheme.Color.textSecondary)
        }
    }

    /// A recommended-userscript row: favicon, name, blurb, and a Get button that opens the script's Greasy
    /// Fork page in BrownBear (where Install hands the .user.js to the userscript engine).
    private func userscriptRow(_ script: RecommendedUserscript) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: script.iconURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFit().padding(7)
                } else {
                    Image(systemName: "doc.text.fill").font(.system(size: 16))
                        .foregroundStyle(BBTheme.Color.textSecondary)
                }
            }
            .frame(width: 40, height: 40)
            .background(BBTheme.Color.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(script.name).font(.body.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                    Text("Open source")
                        .font(.caption2.weight(.semibold)).foregroundStyle(BBTheme.Color.secure)
                }
                Text(script.blurb)
                    .font(.caption)
                    .foregroundStyle(BBTheme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button {
                if let url = script.pageURL {
                    NotificationCenter.default.post(name: .brownBearOpenURL, object: nil, userInfo: ["url": url])
                }
            } label: {
                Text("Get").font(.subheadline.weight(.bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(BBTheme.Color.accent)
        }
        .listRowBackground(BBTheme.Color.card)
    }

    /// A row that opens a userscript repository's homepage in BrownBear (the browser handles the
    /// notification, dismisses this dashboard, and loads it in a new tab).
    private func repoRow(_ repo: UserscriptRepoLink) -> some View {
        Button {
            NotificationCenter.default.post(name: .brownBearOpenURL, object: nil, userInfo: ["url": repo.url])
        } label: {
            HStack(spacing: 12) {
                AsyncImage(url: repo.iconURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit().padding(7)
                    } else {
                        Image(systemName: "bag.fill").font(.system(size: 15))
                            .foregroundStyle(BBTheme.Color.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)
                .background(BBTheme.Color.fieldFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                Text(repo.name).font(.body.weight(.semibold)).foregroundStyle(BBTheme.Color.textPrimary)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(BBTheme.Color.textSecondary)
            }
        }
        .listRowBackground(BBTheme.Color.card)
    }
}

extension RecommendedScriptsSections {
    /// Curated userscripts — popular, reputable, deliberately distinct from the recommended *extensions*
    /// (no overlapping function) and useful on a touch browser. They run on BrownBear's own userscript
    /// engine; "Get" opens the script's Greasy Fork page to install.
    static let recommendedUserscripts: [RecommendedUserscript] = [
        RecommendedUserscript(id: 431691, name: "Bypass All Shortlinks",
                              blurb: "Skips ad-link shorteners — AdFly, Linkvertise, and more — straight to the destination.",
                              iconDomain: "greasyfork.org"),
        RecommendedUserscript(id: 4881, name: "AdsBypasser",
                              blurb: "Auto-skips ad gateways, “continue” pages, and countdown timers on file and image hosts.",
                              iconDomain: "greasyfork.org"),
        RecommendedUserscript(id: 419215, name: "AutoPager",
                              blurb: "Seamlessly appends the next page — endless scrolling on search results and forums.",
                              iconDomain: "greasyfork.org"),
        RecommendedUserscript(id: 23772, name: "Absolute Enable Right Click & Copy",
                              blurb: "Re-enables copy, text selection, and right-click on sites that block them.",
                              iconDomain: "greasyfork.org"),
        RecommendedUserscript(id: 4255, name: "Linkify Plus Plus",
                              blurb: "Turns plain-text URLs into real clickable links, everywhere.",
                              iconDomain: "greasyfork.org"),
        RecommendedUserscript(id: 412245, name: "GitHub High-Speed Download",
                              blurb: "Faster GitHub file and release downloads via mirror services.",
                              iconDomain: "github.com")
    ]

    /// The userscript repositories, for browsing anything not listed.
    static let repositories: [UserscriptRepoLink] = [
        UserscriptRepoLink(id: "greasyfork", name: "Greasy Fork", iconDomain: "greasyfork.org",
                           urlString: "https://greasyfork.org/en/scripts"),
        UserscriptRepoLink(id: "scriptcat", name: "ScriptCat", iconDomain: "scriptcat.org",
                           urlString: "https://scriptcat.org/en/search"),
        UserscriptRepoLink(id: "openuserjs", name: "OpenUserJS", iconDomain: "openuserjs.org",
                           urlString: "https://openuserjs.org/")
    ]
}
