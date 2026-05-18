#!/usr/bin/env python3
"""Migrate Obsidian vault data to Scribe via its MCP server (port 3333)."""

import json
import time
import threading
import urllib.request
import urllib.error
from typing import Optional

BASE_URL = "http://127.0.0.1:3333"
session_path: Optional[str] = None
session_ready = threading.Event()
_req_id = [0]


def _next_id() -> int:
    _req_id[0] += 1
    return _req_id[0]


def _keep_sse_alive():
    """Open SSE stream, capture session path, then hold connection open."""
    global session_path
    req = urllib.request.Request(BASE_URL + "/sse")
    try:
        with urllib.request.urlopen(req, timeout=300) as f:
            for raw in f:
                line = raw.decode("utf-8").strip()
                if line.startswith("data:"):
                    data = line[5:].strip()
                    if data.startswith("/message"):
                        session_path = data
                        session_ready.set()
                if session_ready.is_set():
                    # Block here to keep the SSE connection alive.
                    time.sleep(300)
                    break
    except Exception as e:
        if not session_ready.is_set():
            print(f"SSE error: {e}")


def _post(payload: dict) -> int:
    assert session_path, "No session"
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BASE_URL + session_path,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req) as f:
        return f.status


def create_task(title: str, notes: str = "", project: str = "",
                priority: str = "none", tags: list = None) -> None:
    args: dict = {"title": title}
    if notes:    args["notes"] = notes
    if project:  args["project"] = project
    if priority and priority != "none":
        args["priority"] = priority
    if tags:     args["tags"] = tags

    try:
        status = _post({
            "jsonrpc": "2.0", "id": _next_id(),
            "method": "tools/call",
            "params": {"name": "create_task", "arguments": args},
        })
        print(f"  [{status}] {title}")
    except Exception as e:
        print(f"  [ERR] {title} — {e}")
    time.sleep(0.05)


def main():
    # Start SSE listener thread.
    t = threading.Thread(target=_keep_sse_alive, daemon=True)
    t.start()
    if not session_ready.wait(timeout=5):
        print("ERROR: Could not connect to Scribe MCP server on port 3333.")
        return

    print(f"Connected — session: {session_path}")

    # MCP handshake.
    _post({"jsonrpc": "2.0", "id": _next_id(), "method": "initialize",
           "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                      "clientInfo": {"name": "obsidian-migration", "version": "1.0"}}})
    time.sleep(0.15)
    _post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
    time.sleep(0.15)

    # ── Operations (from 02_Areas/Todos.md) ──────────────────────────────────
    print("\n── Operations ──")
    ops = [
        ("Remove Niko's access", "", "high"),
        ("Change passwords for all systems", "", "high"),
        ("Provide access for me (self)", "", "high"),
        ("Identify topics that need attention — this/next 2/2-6 weeks",
         "Bucket into: next week · next 2 weeks · 2-6 weeks · everything after.", "high"),
        ("Handover: bring me up to date on all topics",
         "Meetings · Planning · Infra (Pipelines, DA Servers) · Security (Password Management)", "high"),
        ("Different passwords for different realms",
         "Priority: next week.", "high"),
        ("MGT Live to Wildfly — server migration",
         "Next 2 weeks. Issues: Backups, VPN on servers / connection drops, "
         "Technical Account on VPN, open firewall to GitLab Runners. "
         "Leadership sign-off required first.", "medium"),
        ("Disable inactive users (~90 days)",
         "Next 2 weeks. Write deactivation reason in attribute field + ticket. "
         "Sync SSO disable events from backend.", "medium"),
        ("New Monitoring setup",
         "Next 2 weeks. Logs for services, new servers, Wildfly/Quarkus compatible.", "medium"),
        ("Keycloak 24/25 upgrade — containerised service",
         "2-6 week horizon. Containerised, container service.", "low"),
        ("Configuration Management rollout",
         "2-6 week horizon.", "low"),
        ("Feature Flags implementation",
         "2-6 week horizon.", "low"),
        ("User ID unification between different realms",
         "Longer horizon.", "low"),
    ]
    for title, notes, priority in ops:
        create_task(title, notes=notes, project="Operations", priority=priority)

    # ── Tech Roadmap — NOW ────────────────────────────────────────────────────
    print("\n── Tech Roadmap: NOW ──")
    create_task("[CLOUD-001] Cost Reduction project",
                notes="Active. 40-60% infra cost reduction over 12 months via multi-tenancy, "
                      "cluster efficiency, observability optimisation. Phased 12-month roadmap.",
                project="Tech Roadmap", priority="high", tags=["cloud", "cost-reduction"])

    # ── Tech Roadmap — NEXT ───────────────────────────────────────────────────
    print("\n── Tech Roadmap: NEXT ──")
    next_items = [
        ("[ARCH-003] Separate services and databases",
         "Break monolith DB coupling.", ["architecture"]),
        ("[QUAL-001] Unit tests baseline",
         "Set coverage gate per module.", ["quality"]),
        ("[QUAL-002] Integration tests",
         "Real DB, no mocks for migrations.", ["quality"]),
        ("[QUAL-003] SonarQube enforced",
         "Quality gates, block MR on regressions.", ["quality"]),
        ("[CLOUD-002] App-level multi-tenancy",
         "Single Quarkus instance per app type, per-tenant datasource isolation.", ["cloud"]),
        ("[CLOUD-003] Kubernetes (AKS) for all apps",
         "See Project Overview Azure.", ["cloud"]),
        ("[DEVOPS-001] CI/CD for cloud-native deploys",
         "Pipeline parity dev → prod.", ["devops"]),
        ("[DEVOPS-002] Feature flags",
         "Decouple deploy from release.", ["devops"]),
        ("[DEVOPS-003] Config management",
         "Central, versioned, env-aware.", ["devops"]),
        ("[DEVOPS-004] Rollback mechanism",
         "Release management gap identified by Welid.", ["devops"]),
        ("[SEC-001] SQL injection sweep",
         "Market module flagged repeatedly in calibration.", ["security"]),
        ("[SEC-002] Brute-force protection",
         "Rate limiting, account lockout.", ["security"]),
        ("[SEC-003] Secrets out of code",
         "No hard-coded params — flagged by Alex.", ["security"]),
        ("[PERF-001] Application caching",
         "Reduce response time on hot reads.", ["performance"]),
        ("[OBS-001] Latency dashboard — public to team", "", ["observability"]),
        ("[OBS-002] Cloud cost dashboard — public to team", "", ["observability"]),
        ("[DOCS-001] ADRs as standard",
         "adr-creator skill; log decisions on Confluence.", ["documentation"]),
        ("[DOCS-002] UML / diagrams repo",
         "Single source of truth for architecture diagrams.", ["documentation"]),
        ("[DOCS-003] Confluence deployments page auto-updated by GitLab CI", "",
         ["documentation"]),
        ("[PROC-001] Code review process tightening",
         "Checklist enforced — flagged by Peter, Luca.", ["process"]),
        ("[PROC-002] Estimation in roadmap stories",
         "Done before plan freeze — flagged by Peter.", ["process"]),
        ("[CULT-001] Regular tech rounds & internal talks",
         "Internal show-and-tell cadence.", ["culture"]),
    ]
    for title, notes, tags in next_items:
        create_task(title, notes=notes, project="Tech Roadmap", priority="medium", tags=tags)

    # ── Tech Roadmap — LATER ──────────────────────────────────────────────────
    print("\n── Tech Roadmap: LATER ──")
    later_items = [
        ("[ARCH-004] Introduce gRPC",
         "Typed, faster inter-service comms.", ["architecture"]),
        ("[ARCH-005] DDD module boundaries",
         "Re-cut packages along bounded contexts — Peter.", ["architecture"]),
        ("[ARCH-007] Database refactoring",
         "Schema cleanup, archive old Liquibase scripts.", ["architecture"]),
        ("[QUAL-004] Automation tests",
         "Testautomatisierung initiative.", ["quality"]),
        ("[QUAL-005] Performance metrics tests",
         "Regression catch in CI.", ["quality"]),
        ("[QUAL-006] Manual test plan for backend",
         "Smoke checklist per release.", ["quality"]),
        ("[CLOUD-004] On-demand customer onboarding",
         "Automated tenant provisioning.", ["cloud"]),
        ("[CLOUD-005] Multi-cloud / hybrid evaluation",
         "Cost + risk hedge.", ["cloud"]),
        ("[DEVOPS-005] Test environment parity",
         "Dev setup mirrors prod.", ["devops"]),
        ("[DEVOPS-006] Laptop default setup",
         "Automate dev onboarding — Welid.", ["devops"]),
        ("[SEC-004] TISAX compliance maintained",
         "Audit-ready posture.", ["security"]),
        ("[SEC-005] VPN-only servers",
         "Close all public surface.", ["security"]),
        ("[SEC-006] Email signatures auto-applied",
         "Anti-phishing.", ["security"]),
        ("[SEC-007] Validation of malicious input",
         "Framework-level input sanitisation.", ["security"]),
        ("[PERF-002] Query time targets",
         "Slow query budget per module.", ["performance"]),
        ("[PERF-003] Metaspace stability (Payara)",
         "Short-term until Quarkus migration complete.", ["performance"]),
        ("[OBS-003] Per-tenant metrics",
         "Once multi-tenancy lands.", ["observability"]),
        ("[DOCS-004] Test systems registry page", "", ["documentation"]),
        ("[DOCS-005] How-to docs",
         "MR, code review, testing, architecture, libraries.", ["documentation"]),
        ("[PROC-003] Pair programming for new joiners",
         "Faster onboarding.", ["process"]),
        ("[PROC-004] Roadmap items on release plan",
         "Visibility — Luca.", ["process"]),
        ("[PROC-005] New customers on tried-and-tested deploy path",
         "Between migration phases.", ["process"]),
        ("[CULT-002] Cross-team conferences",
         "Quarterly cadence.", ["culture"]),
        ("[CULT-003] Freizeit outdoor activities",
         "Team cohesion.", ["culture"]),
    ]
    for title, notes, tags in later_items:
        create_task(title, notes=notes, project="Tech Roadmap", priority="low", tags=tags)

    # ── Tech Backlog (BL-001 … BL-030) ───────────────────────────────────────
    print("\n── Tech Backlog ──")
    backlog = [
        ("BL-030", "Vendor outreach: Defender for Cloud / Cortana / MIO scanning API",
         "Cordana has no public API — manual export won't scale. On Microsoft "
         "Ultimate+Plus; request API access or export path. Newer vuln/secret-scanning "
         "tickets may cover parts — consolidate before adding tools.",
         ["security", "process"]),
        ("BL-029", "Vulnerability management cadence + Confluence relevance log",
         "Need process before June ISO audit. Monthly/bi-monthly meeting: "
         "Frontend + Backend sessions (Tobi, Hakan, Varij). Every Cordana/npm/Docker "
         "finding gets a Confluence row: relevant?, fix path, deadline, JIRA ticket.",
         ["security", "process"]),
        ("BL-028", "Default ticket routing to domain-owning team",
         "Domain-config changes default to Team Rocket today. Once config-management "
         "ships (DEVOPS-003), route tickets to owning team.",
         ["process"]),
        ("BL-027", "Deploy OpenCost for per-service / per-tenant cost transparency",
         "Need data to pitch DO→Azure consolidation to Eric/Jürgen. "
         "Blocked by BL-026 (Mimir not exposed).",
         ["cloud", "observability"]),
        ("BL-026", "Expose Mimir endpoints behind auth (for OpenCost scrape)",
         "Mimir sits behind reverse-proxy with no read access. OpenCost needs "
         "scrape access with proper auth (OAuth). Prerequisite for BL-027.",
         ["observability", "security"]),
        ("BL-025", "UI test cluster on nightly snapshots",
         "Separate cluster, nightly DB snapshots, automated UI tests. "
         "Blocked by BL-024 and CLOUD-003.",
         ["quality"]),
        ("BL-024", "Ephemeral per-branch environments (Review Apps)",
         "Devs cannot test multiple features in parallel. Per-branch ephemeral env "
         "(nightly Testing DB snapshot + liquibase from branch). "
         "Blocked by CLOUD-003, per-service liquibase split.",
         ["devops"]),
        ("BL-023", "Port-level versioning + user-ID in Bulk-Upload audit",
         "Audit trail only at Project-Level; User-ID is null when not SAP. "
         "Risk: wrong Project-ID overwrites colleague data. "
         "Needs created_by propagation + Port-Level version tracking.",
         ["architecture"]),
        ("BL-022", "DiCash sync robustness",
         "Stale DiCash sync → misuse leads to inconsistent project state. "
         "Need forced-refresh / upload validation.",
         ["architecture"]),
        ("BL-021", "Meeting recording → AI transcript → action items",
         "Stories remembered differently between meetings. "
         "Auto-transcript + AI summary + action items keeps all aligned. "
         "Blocked by Security/Datenschutz review for audio-egress to LLM/STT provider.",
         ["process"]),
        ("BL-020", "Internal AI dev tooling rollout",
         "Claude Code / Copilot lift dev velocity 20-40%. "
         "Need rollout plan, license budget, security review, prompt-engineering enablement. "
         "Blocked by security review of code-egress to LLM providers.",
         ["process"]),
        ("BL-019", "AI infra readiness assessment",
         "Prevent expensive rebuild later. Evaluate: vector store, embedding pipeline, "
         "data contracts, cost model. Decide build vs buy.",
         ["architecture"]),
        ("BL-018", "Mentorship pairs across teams",
         "Cross-pollinate Backend/Ops/Frontend. Reduces bus factor, builds T-shaped engineers.",
         ["culture"]),
        ("BL-017", "Engineering newsletter / brown-bag cadence",
         "Surface internal tech work, celebrate wins, support recruiting. "
         "Companion to CULT-001.",
         ["culture"]),
        ("BL-016", "RFC process for major changes",
         "Forces async architectural debate before implementation. "
         "ADR is the decision; RFC is the proposal. Companion to DOCS-001.",
         ["process"]),
        ("BL-015", "Postmortem template + library",
         "Blameless postmortems compound learning. Without a library, lessons are lost.",
         ["process"]),
        ("BL-014", "On-call rotation formalization",
         "Today informal. Formal rotation + paging tool + escalation policy "
         "reduces burnout and MTTR. Blocked by OBS-001/OBS-002.",
         ["process"]),
        ("BL-013", "Service catalog (Backstage or similar)",
         "Single index of services, owners, runbooks, dashboards, dependencies. "
         "Onboarding accelerator. Foundation for SLO tracking.",
         ["documentation"]),
        ("BL-012", "OpenAPI auto-generated API docs",
         "Spec-first or annotation-driven. Eliminates 'is this endpoint still valid?' "
         "Slack threads. Frontend & external consumers always have current contract.",
         ["documentation"]),
        ("BL-011", "Centralized log aggregation (Loki or ELK)",
         "Cross-service correlation. Faster incident response. Required for SLO computation.",
         ["observability"]),
        ("BL-010", "SLO definitions per service + error budgets",
         "Move from 'is it up?' to 'is it meeting promise?'. "
         "Blocked by OBS-001, BL-011.",
         ["observability"]),
        ("BL-009", "OpenTelemetry distributed tracing",
         "Trace requests through Master/Reports/Market. "
         "Drastically cuts debug time on prod incidents.",
         ["observability"]),
        ("BL-008", "DB index review program",
         "Recurring slow queries flagged. Quarterly index review + slow-query log. "
         "Quick payoff before big architecture moves.",
         ["performance"]),
        ("BL-007", "Backup integrity & restore drills",
         "Untested backup = no backup. Quarterly fire drill validates RPO/RTO. TISAX-friendly.",
         ["security"]),
        ("BL-006", "Container image vulnerability scanning (Trivy)",
         "Block vulnerable base images at build time. Required for AKS rollout (CLOUD-003).",
         ["security"]),
        ("BL-005", "Dependency scanning + auto-PRs (Renovate)",
         "Renovate generates MRs for dep updates. Addresses outdated-libs pain "
         "named by Dominic, Peter, Luca. Compounds with QUAL-003 SonarQube.",
         ["security"]),
        ("BL-004", "IaC for AKS (Terraform or Bicep)",
         "Click-ops in Azure portal won't scale. Required before CLOUD-003 lands. "
         "Reproducible envs, peer-reviewable infra.",
         ["cloud"]),
        ("BL-003", "GitLab pipeline shared library",
         "Each repo has bespoke .gitlab-ci.yml. Shared include: library = "
         "consistent quality gates, faster repo onboarding, single rollout point.",
         ["devops"]),
        ("BL-002", "Standardise on one JSON library (Jackson)",
         "Jackson + JSON-P used inconsistently (Dominic 1:1). "
         "Reduces cognitive load, eliminates serialisation mismatch bugs. Migration is mechanical.",
         ["architecture"]),
        ("BL-001", "Mutation testing pilot (PIT)",
         "Coverage gates (QUAL-001) are gameable. Mutation testing reveals "
         "tests that don't actually test anything. Pilot one module. Blocked by QUAL-001.",
         ["quality"]),
    ]
    for bl_id, title, notes, tags in backlog:
        create_task(f"[{bl_id}] {title}", notes=notes, project="Tech Backlog", tags=tags)

    print("\n✓ Migration complete.")


if __name__ == "__main__":
    main()
