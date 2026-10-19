# Vendored dependencies

OpenZeppelin/openzeppelin-contracts v5.0.2
Source: https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
Archive SHA-256: 18c7b7e949b9a82dcd8cd394426c9c2636dfc263aa2317d4749dbfa0c7b3925a
Vendored files: 13

foundry-rs/forge-std v1.9.7
Source: https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7
Archive SHA-256: 45157353ab49eab01d294565866731e599b32401757229689ee459aa26b7ee94
Vendored files: 30

OpenZeppelin contains only the required source dependency closure and its MIT license. Forge Std contains its src tree and both license files. Sources are unmodified except that `forge fmt` reformatted whitespace in `utils/Address.sol` and `token/ERC20/extensions/IERC20Permit.sol` (with all whitespace removed they hash identically to upstream; no code changed). All dependencies are ordinary files; no submodules or network downloads are needed to build.
