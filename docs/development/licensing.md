# Licence proposal

Recommended model: **Apache License 2.0 for original Squad code and documentation**,
with contributions accepted under the same terms. No separate commercial edition
or mandatory contributor licence agreement is proposed.

Apache-2.0 permits use, modification and distribution, including commercial use,
provides an explicit contributor patent grant, requires preservation of applicable
notices, and does not grant trademark rights. These terms fit a reusable agent
workflow that people may embed in their own tooling. See the
[official licence](https://www.apache.org/licenses/LICENSE-2.0).

Alternatives:

| Licence | Main tradeoff |
| --- | --- |
| [MIT](https://choosealicense.com/licenses/mit/) | Short permissive terms; no comparable explicit patent grant in the text |
| [AGPL-3.0](https://choosealicense.com/licenses/agpl-3.0/) | Strong reciprocity, including source availability for modified software offered over a network; greater integration obligations |

The owner's decision is required before applying a licence. Until then, manifests
remain UNLICENSED and the README must not call the release open source. Public
visibility alone does not grant open-source rights.

Third-party components retain their own licences. The Codex Go adapter imports
`github.com/gorilla/websocket` (BSD-2-Clause) through Go modules; its source is not
vendored. If distributing compiled binaries in future, include all required
third-party notices. Provider products, subscriptions and trademarks are not
licensed by Squad's repository licence.
