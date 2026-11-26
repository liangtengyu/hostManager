import Foundation
import HostManagerCore

/// The groups a fresh installation starts with. All switched off, so nothing reaches the
/// hosts file until the user says so; they exist to show what a group, and a nested one,
/// looks like. Every hostname ends in `.test`, which can never resolve on the public Internet,
/// and the addresses are loopback or documentation ranges.
enum SampleGroups {
    static func make() -> [HostGroup] {
        [
            HostGroup(name: L10n.t("sample.localDevelopment"), content: localDevelopment),
            HostGroup(name: L10n.t("sample.staging"), content: staging),
            HostGroup(name: L10n.t("sample.qa"), content: qa),
            HostGroup(name: L10n.t("sample.sandbox"), content: sandbox),
            HostGroup(name: L10n.t("sample.production"), content: production),
            HostGroup(name: L10n.t("sample.team"), icon: "globe", content: team),
            HostGroup(
                name: L10n.t("sample.project"),
                children: [
                    HostGroup(name: L10n.t("sample.websitePreview"), content: websitePreview),
                    HostGroup(name: L10n.t("sample.mobileBackend"), content: mobileBackend),
                    HostGroup(name: L10n.t("sample.integrationTests"), content: integrationTests),
                ]
            ),
        ]
    }

    private static let localDevelopment = """
    # Local Development
    # Host mappings for the local development environment.
    # Enable this profile before starting local services.

    # Web applications
    127.0.0.1\tapp.example.test
    127.0.0.1\tadmin.example.test
    127.0.0.1\tdocs.example.test

    # Backend services
    127.0.0.1\tapi.example.test
    127.0.0.1\tauth.example.test
    127.0.0.1\tassets.example.test

    # Internal tools
    127.0.0.1\tdashboard.example.test
    127.0.0.1\tmail.example.test

    # Container services
    192.168.56.10\tregistry.example.test
    192.168.56.11\tmetrics.example.test
    """

    private static let staging = """
    # Staging Environment
    # Shared staging servers for release verification.

    # Web
    203.0.113.10\tstaging.example.test
    203.0.113.10\tadmin.staging.example.test

    # Services
    203.0.113.20\tapi.staging.example.test
    203.0.113.21\tdb.staging.example.test
    """

    private static let qa = """
    # QA Environment
    # Isolated QA cluster used by the QA team.

    10.8.0.11\tqa.example.test
    10.8.0.12\tapi.qa.example.test
    10.8.0.13\tqa-db.example.test
    """

    private static let sandbox = """
    # API Sandbox
    # Sandbox endpoints for third-party API testing.

    127.0.0.1\tsandbox-api.example.test
    127.0.0.1\tsandbox-web.example.test
    127.0.0.1\tmock-auth.example.test
    """

    private static let production = """
    # Production Reference
    # Read-only reference of production endpoints.
    # Keep this profile switched off unless investigating a live issue.

    # Edge
    198.51.100.30\twww.example.test
    198.51.100.31\tapi.example.test

    # Infrastructure
    198.51.100.40\tdb.example.test
    198.51.100.41\tcache.example.test
    """

    private static let team = """
    # Team Hosts
    # Shared hosts maintained by the team.

    # Design
    192.168.56.50\tdesign.example.test

    # Review
    192.168.56.51\treview.example.test
    """

    private static let websitePreview = """
    # Website Preview
    # Preview builds served by the local web server.

    127.0.0.1\tpreview.example.test
    127.0.0.1\twww.preview.example.test
    """

    private static let mobileBackend = """
    # Mobile Backend
    # Local backend used by the mobile apps on the LAN.

    192.168.56.60\tmobile-api.example.test
    192.168.56.60\tpush.example.test
    """

    private static let integrationTests = """
    # Integration Tests
    # Hostnames resolved only while running the integration suite.

    127.0.0.1\tintegration.example.test
    127.0.0.1\tworker.integration.example.test
    """
}
