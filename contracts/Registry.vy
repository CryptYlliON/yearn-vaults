# @version 0.2.7

interface DetailedERC20:
    def name() -> String[52]: view
    def symbol() -> String[30]: view


interface Vault:
    def token() -> address: view
    def apiVersion() -> String[28]: view
    def initialize(
        token: address,
        governance: address,
        name: String[64],
        symbol: String[32],
        guardian: address,
    ): nonpayable


# len(Vault.releases)
nextRelease: public(uint256)
releases: public(HashMap[uint256, address])

# Token.address => len(Vault.deployments)
nextDeployment: public(HashMap[address, uint256])
vaults: public(HashMap[address, HashMap[uint256, address]])

# 2-phase commit
governance: public(address)
pending_governance: address


event NewRelease:
    event_id: indexed(uint256)
    template: address
    api_version: String[28]

event NewVault:
    token: indexed(address)
    event_id: indexed(uint256)
    vault: address
    api_version: String[28]


@external
def __init__():
    self.governance = msg.sender


@external
def setGovernance(_governance: address):
    assert msg.sender == self.governance  # dev: unauthorized
    self.pending_governance = _governance


@external
def acceptGovernance():
    assert msg.sender == self.pending_governance  # dev: unauthorized
    self.governance = msg.sender


@internal
def _addVault(token: address, vault: address):
    deployment_id: uint256 = self.nextDeployment[token]  # Next id in series
    self.vaults[token][deployment_id] = vault
    self.nextDeployment[token] = deployment_id + 1

    log NewVault(token, deployment_id, vault, Vault(vault).apiVersion())


@external
def newRelease(vault: address):
    """
    @notice
        Add a previously deployed Vault as a vault for a particular release
    @dev
        The Vault must be a valid Vault, and should be the next in the release series, meaning
        semver is being followed. The code does not check for that, only that the release is not
        the same as the previous one.
    @param vault The deployed Vault to use as the cornerstone template for the given release.
    """
    assert msg.sender == self.governance  # dev: unauthorized

    release_id: uint256 = self.nextRelease  # Next id in series
    api_version: String[28] = Vault(vault).apiVersion()
    if release_id > 0:
        assert Vault(self.releases[release_id - 1]).apiVersion() != api_version

    self.releases[release_id] = vault
    self.nextRelease = release_id + 1

    log NewRelease(release_id, vault, api_version)

    # Also register the release as a new Vault
    self._addVault(Vault(vault).token(), vault)


@external
def newVault(
    token: address,
    guardian: address,
    nameOverride: String[64] = "",
    symbolOverride: String[32] = "",
) -> address:
    """
    @notice
        Add a new deployed vault for the given token as a simple "forwarder-style" proxy to the
        latest version being managed by this registry
    @dev
        If `nameOverride` is not specified, the name will be 'yearn' combined with the name of
        `token`.

        If `symbolOverride` is not specified, the symbol will be 'yv' combined with the symbol
        of `token`.
    @param token The token that may be deposited into this Vault.
    @param guardian The address authorized for guardian interactions.
    @param nameOverride Specify a custom Vault name. Leave empty for default choice.
    @param symbolOverride Specify a custom Vault symbol name. Leave empty for default choice.
    @return The address of the newly-deployed vault
    """
    assert msg.sender == self.governance  # dev: unauthorized

    # NOTE: Underflow if no releases created yet (this is okay)
    vault: address = create_forwarder_to(self.releases[self.nextRelease - 1])

    name: String[64] = nameOverride
    if name == "":
        name = concat("Yearn ", DetailedERC20(token).name(), " Vault")

    symbol: String[32] = symbolOverride
    if symbol == "":
        symbol = concat("yv", DetailedERC20(token).symbol())

    # NOTE: Must initialize the Vault atomically with deploying it
    Vault(vault).initialize(token, msg.sender, name, symbol, guardian)

    self._addVault(token, vault)

    return vault
