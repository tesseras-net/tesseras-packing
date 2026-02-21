# Tesseras packing

Interactive packing for the [Tesseras](https://tesseras.net) DHT network.

## About

Tesseras packing is an interactive command-line shell for storing and retrieving
content on the Tesseras P2P network. It spawns a local DHT node and provides a
readline-based interface with command completion, history, and an editor
integration for composing multi-line content.

On first run the node generates an Ed25519 identity and performs proof-of-work,
which may take a moment. Subsequent starts are instant. Data is persisted under
`~/.local/share/tesseras/` (or `$XDG_DATA_HOME/tesseras/`).

## Links

- [Website](https://tesseras.net)
- [Documentation](https://tesseras.net/book/en/)
- [Source code](https://git.sr.ht/~ijanc/tesseras-packing) (primary)
- [GitHub mirror](https://github.com/tesseras-net/tesseras-packing)
- [Ticket tracker](https://todo.sr.ht/~ijanc/tesseras)
- [Mailing lists](https://tesseras.net/subscriptions/)

## License

ISC — see [LICENSE](LICENSE).
