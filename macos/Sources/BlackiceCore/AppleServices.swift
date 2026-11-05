// macOS's own services, allowed without a rule unless blackice.toml says `apple_services = false`.
//
// The first ask-mode runs on a Mac (3 November 2026) paused iCloud, CalDAV, Software Update, Maps and
// AuthKit, then dropped them at the deadline, and the user's own events were a few among dozens. This
// table lets those services through in ask and block-all. It maps a signing identifier to the hosts
// that service may reach. An entry counts only when both hold:
// - the flow's identity is verified Apple platform code: a signing identity with no Team ID, which
//   CodeIdentity gives only to code that satisfies `anchor apple` (signed by Apple itself; the CLI
//   shows it as "apple/<id>"). Third-party code that calls itself com.apple.something has a Team ID,
//   and so do Apple's developer tools installed with the Command Line Tools (git, python3 and
//   swift-frontend carry Team ID 59GAB85EFG), so neither matches;
// - the host matches one of the entry's patterns and the flow's address is among the host's answers
//   from the system resolver, the same check an [[allow]] rule gets.
// A flow it allows is logged with the reason `apple_service`. Rules come first, so a rule's line
// still shows in the log when a rule also covers the flow.
//
// Never here: code that runs commands or fetches URLs on someone else's behalf. curl, nscurl,
// python3, perl, ruby, the shells, ssh, scp, nc, git, osascript, Safari, WebKit's networking process
// and nsurlsessiond (which downloads for any app) are left out, and AppleServicesTests checks it. An
// agent that uses them still needs a rule or an approval. So is accountsd, which signs in to the
// accounts the user adds (Google's among them); dataaccessd and the contacts sync get iCloud only.
//
// Where each entry comes from:
// - "Mac": seen in the daemon's event log (events.jsonl) during ask-mode runs on a MacBook Air with
//   macOS 27.0.1, from 3 November 2026; the runs are named in parentheses after the first ones. The
//   seen host is widened to the Apple domain the service uses (ls.apple.com to *.apple.com, for
//   example), or kept alone where the service needs no other ("only that host"). An iCloud host
//   that starts with pNNN- names the account's partition (p404 on that Mac), which differs between
//   accounts, so an entry that saw one takes *.icloud.com.
// - "Apple": the hosts Apple lists for that feature in "Use Apple products on enterprise networks"
//   (support.apple.com/101555).
// - "known": a well-known macOS service whose signing identifier was read with `codesign -dv` on the
//   same Mac, with the Apple domains it is known to use.
// Some flows carry the name a host's CNAME points to rather than the host itself (geod's akadns.net
// host on the Mac), so iCloud entries also list apple-dns.net and update entries aaplimg.com, both
// Apple's own domains for those targets.
//
// Certificate checks: trustd (and ocspd, which macOS 27 still ships) fetch OCSP responses, CRLs and
// missing intermediate certificates from the URLs inside the certificate being checked. They get a
// fixed list of certificate authority hosts, not "any host on port 80": since a certificate names its
// own URLs, any app could make trustd fetch from a host of its choosing by evaluating a certificate it
// made, which would be a way out for data in block-all. A CA missing from the list is asked about in
// ask mode and dropped in block-all. Apple's default revocation check is best effort, so mostly that
// costs a revocation answer; a server that leaves out an intermediate certificate, which trustd would
// have fetched, fails the trust check.

public enum AppleServices {
    /// Hosts for certificate checks: Apple's own, the others Apple lists for certificate validation
    /// (DigiCert, Entrust), and the CAs that issue most public TLS certificates.
    static let certificateHosts = [
        "*.apple.com",                                      // ocsp, ocsp2, crl, valid, certs.apple.com
        "*.digicert.com", "ocsp.digicert.cn",               // Apple; also GeoTrust, RapidSSL, Thawte
        "*.entrust.net",                                    // Apple
        "*.lencr.org",                                      // Let's Encrypt
        "*.sectigo.com", "*.usertrust.com", "*.comodoca.com", // Sectigo
        "*.globalsign.com",                                 // GlobalSign
        "*.godaddy.com", "*.starfieldtech.com",             // GoDaddy, Starfield
        "pki.goog", "*.pki.goog",                           // Google Trust Services
        "*.amazontrust.com",                                // Amazon
        "*.msocsp.com", "oneocsp.microsoft.com", "crl.microsoft.com", "www.microsoft.com", // Microsoft
    ]

    /// Signing identifier (Apple platform code only) and host patterns, sorted by identifier.
    static let entries: [(signingID: String, hosts: [String])] = [
        // Mac (0.3 runs, 3–4 November 2026): init.itunes.apple.com, bag.itunes.apple.com. Music's
        // artwork. Only those hosts.
        ("com.apple.AMPArtworkAgent", ["init.itunes.apple.com", "bag.itunes.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): init.itunes.apple.com, bag.itunes.apple.com. Music's
        // library. Only those hosts.
        ("com.apple.AMPLibraryAgent", ["init.itunes.apple.com", "bag.itunes.apple.com"]),
        // Mac (0.3.0 runs): p404-contacts.icloud.com. iCloud contacts only: like dataaccessd, it also
        // syncs any other account the user adds, which needs a rule.
        ("com.apple.AddressBookSourceSync", ["*.icloud.com", "*.apple-dns.net"]),
        // Mac (0.3 runs, 3–4 November 2026): lcdn-locator.apple.com. Finds a content cache on the
        // network. Only that host.
        ("com.apple.AssetCacheLocatorService", ["lcdn-locator.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): init.ess.apple.com. Call history sync. Only that host.
        ("com.apple.CallHistorySyncHelper", ["init.ess.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): p404-quota.icloud.com. iCloud features of the account.
        ("com.apple.FeatureAccessAgent", ["*.icloud.com"]),
        // Mac (0.3 runs, 3–4 November 2026): websitereview.corp.apple.com. Safari's Safe Browsing
        // service, not Safari or WebKit, which fetch any URL. Only that host.
        ("com.apple.Safari.SafeBrowsing", ["websitereview.corp.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): stocks-data-service.apple.com. Spotlight's settings.
        // Only that host.
        ("com.apple.Spotlight-Settings.extension", ["stocks-data-service.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): radarsubmissions.apple.com. Diagnostics the user
        // chose to share. Only that host.
        ("com.apple.SubmitDiagInfo", ["radarsubmissions.apple.com"]),
        // Mac: gsas.apple.com. AuthKit, Apple Account sign-in.
        ("com.apple.akd", ["*.apple.com", "*.icloud.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com. Apple Media Services accounts.
        // Only that host.
        ("com.apple.amsaccountsd", ["bag.itunes.apple.com"]),
        // Mac (0.3.0 runs): amp-api.media.apple.com, bag.itunes.apple.com, xp.apple.com,
        // apps.mzstatic.com. Apple Media Services, behind the App Store, Music and TV.
        ("com.apple.amsengagementd", ["*.apple.com", "*.mzstatic.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com. Apple Media Services storage.
        // Only that host.
        ("com.apple.amsondevicestoraged", ["bag.itunes.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com, partiality.itunes.apple.com.
        // Apple's ad privacy service. Only those hosts.
        ("com.apple.ap.adprivacyd", ["bag.itunes.apple.com", "partiality.itunes.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): device-config.pcms.apple.com. Apple's promoted content.
        // Only that host.
        ("com.apple.ap.promotedcontentd", ["device-config.pcms.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): setup.icloud.com. The Apple Account. Only that host.
        ("com.apple.appleaccountd", ["setup.icloud.com"]),
        // known: App Store downloads and updates. Apple: App Store hosts.
        ("com.apple.appstoreagent", ["*.apple.com", "*.mzstatic.com", "*.cdn-apple.com"]),
        ("com.apple.appstored", ["*.apple.com", "*.mzstatic.com", "*.cdn-apple.com"]),
        // Apple: push notifications, *.push.apple.com.
        ("com.apple.apsd", ["*.push.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): api2.smoot.apple.com. Siri. Only that host.
        ("com.apple.assistantd", ["api2.smoot.apple.com"]),
        // known: captive portal detection.
        ("com.apple.captiveagent", ["captive.apple.com"]),
        // Mac: gateway.icloud.com. Apple: iCloud and CloudKit hosts.
        ("com.apple.cloudd", ["*.icloud.com", "*.icloud-content.com", "*.apple-cloudkit.com", "*.apple-dns.net"]),
        // Mac (0.3 runs, 3–4 November 2026): gateway.icloud.com. iCloud's telemetry. Only that host.
        ("com.apple.cloudtelemetryd", ["gateway.icloud.com"]),
        // known: App Store purchases. Apple: App Store hosts.
        ("com.apple.commerce", ["*.apple.com", "*.mzstatic.com"]),
        // Mac: www.apple.com. Only that host.
        ("com.apple.controlcenter", ["www.apple.com"]),
        // Mac (0.3.0 runs): amp-api.apps.apple.com, bag.itunes.apple.com. App categories, which
        // Screen Time uses.
        ("com.apple.ctcategories.service", ["*.apple.com"]),
        // Mac: p404-caldav.icloud.com. iCloud calendars and contacts only: dataaccessd also syncs any
        // other account the user adds (the Mac showed calendar.google.com), which needs a rule.
        ("com.apple.dataaccess.dataaccessd", ["*.icloud.com", "*.apple-dns.net"]),
        // Mac (0.3 runs, 3–4 November 2026): p404-fmipmobile.icloud.com. The Find My app.
        ("com.apple.findmy", ["*.icloud.com"]),
        // Mac (0.3 runs, 3–4 November 2026): gateway.icloud.com. Find My's location agent. Only that
        // host.
        ("com.apple.findmy.findmylocateagent", ["gateway.icloud.com"]),
        // Mac: gsp57-ssl-background.ls.apple.com, and background-weighted.ls4-apple.com.akadns.net, a
        // CNAME target in Apple's zone at Akamai. Maps and location services.
        ("com.apple.geod", ["*.apple.com", "*.ls4-apple.com.akadns.net"]),
        // Mac (0.3 runs, 3–4 November 2026): cds.apple.com. Help's content. Only that host.
        ("com.apple.helpd", ["cds.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): setup.icloud.com, p404-quota.icloud.com. iCloud
        // settings and storage.
        ("com.apple.iCloudHelper", ["*.icloud.com"]),
        // Mac (0.3 runs, 3–4 November 2026): gateway.icloud.com, p404-fmipmobile.icloud.com. Find
        // My's network of devices.
        ("com.apple.icloud.searchpartyuseragent", ["*.icloud.com"]),
        // known: iMessage and FaceTime identities (*.ess.apple.com).
        ("com.apple.identityservicesd", ["*.apple.com", "*.icloud.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com. iCloud Music Library. Only that
        // host.
        ("com.apple.itunescloudd", ["bag.itunes.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com. Apple Media Services assets. Only
        // that host.
        ("com.apple.jetpackassetd", ["bag.itunes.apple.com"]),
        // known: Wi-Fi location, which also sets the time zone (gs-loc.apple.com).
        ("com.apple.locationd", ["*.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com. Managed app distribution. Only
        // that host.
        ("com.apple.managedappdistributionagent", ["bag.itunes.apple.com"]),
        // Mac: gdmf.apple.com, xp.apple.com. Apple: software update hosts.
        ("com.apple.mobileassetd", ["*.apple.com", "*.cdn-apple.com", "*.aaplimg.com"]),
        // Mac: mask-api.icloud.com, iCloud Private Relay's configuration. Only that host.
        ("com.apple.networkserviceproxy", ["mask-api.icloud.com"]),
        // known (codesign: /usr/sbin/ocspd): legacy revocation checks. Same hosts as trustd.
        ("com.apple.ocspd", certificateHosts),
        // Mac (0.3 runs, 3–4 November 2026): swallow.apple.com. Feedback on Spotlight and Siri
        // suggestions. Only that host.
        ("com.apple.parsec-fbf", ["swallow.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): api.smoot.apple.com. Spotlight and Siri suggestions.
        // Only that host.
        ("com.apple.parsecd", ["api.smoot.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): bag.itunes.apple.com. Photos' analysis. Only that host.
        ("com.apple.photoanalysisd", ["bag.itunes.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): gateway-oblivious.apple.com. Private Cloud Compute. Only
        // that host: it also reached apple-relay.fastly-edge.com, which is not on Apple's domain and
        // is asked about.
        ("com.apple.privatecloudcomputed", ["gateway-oblivious.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): pancake.apple.com. FaceTime call quality reports. Only
        // that host.
        ("com.apple.rtcreportingd", ["pancake.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): p404-escrowproxy.icloud.com. iCloud Keychain escrow.
        ("com.apple.sbd", ["*.icloud.com"]),
        // Mac (building 0.3.1 in ask mode): timestamp.apple.com on port 80, the timestamp codesign
        // asks for. Without an answer in time the signature has no timestamp. Only that host.
        ("com.apple.security.XPCTimeStampingService", ["timestamp.apple.com"]),
        // Mac: swscan.apple.com, xp.apple.com. Apple: software update hosts.
        ("com.apple.softwareupdated", ["*.apple.com", "*.cdn-apple.com", "*.aaplimg.com"]),
        // Mac (0.3 runs, 3–4 November 2026): www.apple.com. Only that host.
        ("com.apple.studentd", ["www.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): app-site-association.cdn-apple.com. Associated domains,
        // through Apple's CDN. Only that host: a fetch from an app's own domain is asked about.
        ("com.apple.swcd", ["app-site-association.cdn-apple.com"]),
        // Mac: api.apple-cloudkit.com, Gatekeeper's notarization ticket lookup.
        ("com.apple.syspolicyd", ["*.apple-cloudkit.com"]),
        // Mac (0.3 runs, 3–4 November 2026): gsa.apple.com. Apple Account in System Settings. Only
        // that host.
        ("com.apple.systempreferences.AppleIDSettings", ["gsa.apple.com"]),
        // known: network time from time.apple.com, which points into aaplimg.com.
        ("com.apple.timed", ["*.apple.com", "*.aaplimg.com"]),
        // Mac (build 4 run): ipcdn.apple.com. The Tips app's content.
        ("com.apple.tipsd", ["*.apple.com"]),
        // Mac (0.3 runs, 3–4 November 2026): kt-prod.ess.apple.com. Key transparency for iMessage
        // and FaceTime. Only that host.
        ("com.apple.transparencyd", ["kt-prod.ess.apple.com"]),
        // Apple: certificate validation. See the comment at the top of this file.
        ("com.apple.trustd", certificateHosts),
        // Mac (0.3 runs, 3–4 November 2026): configuration.apple.com, sylvan.apple.com. Aerial
        // wallpapers. Only those hosts.
        ("com.apple.wallpaper.extension.aerials", ["configuration.apple.com", "sylvan.apple.com"]),
    ]

    /// The patterns of each entry, by signing identifier.
    static let table: [String: [DomainPattern]] = Dictionary(
        entries.map { ($0.signingID, $0.hosts.compactMap(DomainPattern.init)) },
        uniquingKeysWith: { first, _ in first })

    /// Whether the table has an entry for this code at all. Apple platform code only.
    public static func covers(_ identity: SigningIdentity) -> Bool {
        identity.teamID == nil && table[identity.signingID] != nil
    }

    /// Whether this Apple service may reach this host. `host` must already be normalized; the
    /// caller still checks the flow's address against it.
    public static func allows(_ identity: SigningIdentity, host: String) -> Bool {
        guard identity.teamID == nil, let patterns = table[identity.signingID] else { return false }
        return patterns.contains { $0.matches(host) }
    }
}
