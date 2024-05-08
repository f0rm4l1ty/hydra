module.exports = {
  userDocumentation: [
    {
      type: "doc",
      label: "Welcome",
      id: "index",
    },
    {
      type: "doc",
      id: "protocol-overview",
      label: "Protocol overview",
    },
    "known-issues",
    {
      type: "html",
      value: "<small><b>Tutorials</b></small>",
      defaultStyle: true,
      className: "sidebar-header",
    },
    {
      type: "doc",
      id: "getting-started",
      label: "Getting started",
    },
    {
      type: "doc",
      id: "tutorial",
      label: "Open a head on testnet",
    },
    {
      type: "html",
      value: "<small><b>Documentation</b></small>",
      defaultStyle: true,
      className: "sidebar-header",
    },
    {
      type: "doc",
      id: "installation",
      label: "Installation",
    },
    {
      type: "doc",
      id: "configuration",
      label: "Configuration",
    },
    {
      type: "category",
      label: "How to ...",
      // collapsed: true,
      // collapsible: true,
      items: [
        {
          type: "autogenerated",
          dirName: "how-to",
        },
      ],
    },
    {
      type: "html",
      value: "<small><b>Reference</b></small>",
      defaultStyle: true,
      className: "sidebar-header",
    },
    {
      type: "link",
      href: "https://github.com/input-output-hk/hydra/releases",
      label: "Release notes",
    },
    {
      type: "link",
      href: "/api-reference",
      label: "API reference",
    },
    {
      type: "link",
      href: "/benchmarks",
      label: "Benchmarks",
    },
  ],

  developerDocumentation: [
    {
      type: "autogenerated",
      dirName: "dev",
    },
    {
      type: "link",
      href: "/adr",
      label: "Architecture Decision Records",
    },
  ],
};
