# AI Disclosure

Transparently, every file in this repo was touched by Claude Code at some point, with the exception of this document. I made very liberal use of AI tools for implementing code and instead focused on reusability, tool choices, and architectural and design patterns.

Things I did not do:
- Claude here are the requirements please go build this

Things I did do:
- Built a kubeadm cluster outside of the automation for testing
- Tested universal deployment on GKE
- Lots of reviewing generated code
- Lots of guiding design and implementation decisions
- Simplified things, removing components where it didn't necessarily add substance to the demonstration
- Removed a lot of Claude-speak from documentation
- Maintained and tested some semblance of developer UX and portability
- 100% definitely vibe-coded an `index.html` asset for my nginx service, or at least brought along the one created when I originally applied for this role. Of all the files in this repo I would probably struggle to navigate `nginx/files/index.html `the most.

I am happy to answer questions and receive feedback on any of the components or decisions made in this codebase.