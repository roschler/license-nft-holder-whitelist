# Hook Template: `LicenseNftHolderWhitelistHook.sol`

# LicenseNftHolderWhitelistHook

Gates Story Protocol license **minting/derivative registration** by requiring the **caller** to currently hold at least one ERC-721 token from **any** NFT contract whitelisted for the specific license scope.

Scope is keyed as:
```
key = keccak256(ipOwner, licensorIpId, licenseTemplate, licenseTermsId)
```
This mirrors the official sample and ensures isolation across different IPs/templates/terms, and across ownership changes of the IP (the `ipOwner` is part of the key).

## Sample Use Case

For example, suppose **@hobbikats** wanted to restrict the minting of a new IP asset she created named **SPECIAL‑LARRY** to only people who owned a *Bored Ape Yacht Club* token. She would register **SPECIAL‑LARRY** with this custom license hook and then add the BAYC contract address to the whitelist using the provided owner‑only function. Other functions are available for maintaining the whitelist contents.

## What it does

- **Whitelist management per license scope**
    - Whitelist specific ERC-721 contracts per license scope (allow‑list only; no deny‑list).
    - Compact on‑chain list with O(1) **swap‑and‑pop** removal.

- **Gating checks**
    - `beforeMintLicenseTokens(...)`: reverts unless the **caller** owns ≥1 token from any whitelisted ERC‑721 in scope.
    - `beforeRegisterDerivative(...)`: same gating for derivative registration (parent scope).
    - `calculateMintingFee(...)`: reads fee from the license template and multiplies by `amount`.

- **Interface validation**
    - Confirms target NFT is a deployed contract that reports **ERC‑721** via **ERC‑165** before whitelisting.

- **Permissions**
    - Admin operations (`addWhitelistNft`, `removeWhitelistNft`) are protected by `verifyPermission(licensorIpId)` (from Story Protocol `AccessControlled`).

## Constructor

```solidity
constructor(
    address accessController,
    address ipAssetRegistry,
    address licenseRegistry
)
```

- `accessController`, `ipAssetRegistry` are passed to `AccessControlled`.
- `licenseRegistry` is stored as immutable `LICENSE_REGISTRY` (zero‑address is rejected).

## Storage layout (per scope)

- `mapping(bytes32 => mapping(address => bool)) whitelistedNfts`
- `mapping(bytes32 => address[]) whitelistedNftList`
- `mapping(bytes32 => mapping(address => uint256)) nftIndex1Based`  
  Used to keep `whitelistedNftList` compact with swap‑and‑pop deletes.

## External API

### Admin

```solidity
function addWhitelistNft(
    address licensorIpId,
    address licenseTemplate,
    uint256 licenseTermsId,
    address nftContract
) external verifyPermission(licensorIpId);
```
- Requires: the license terms are already **attached** to `licensorIpId` in `LICENSE_REGISTRY`.
- Validates `nftContract` is a contract and supports **ERC‑721** via **ERC‑165**.
- Reverts if already whitelisted.

```solidity
function removeWhitelistNft(
    address licensorIpId,
    address licenseTemplate,
    uint256 licenseTermsId,
    address nftContract
) external verifyPermission(licensorIpId);
```
- Removes the contract from the scope’s whitelist (swap‑and‑pop).
- Reverts if not whitelisted.

### Read

```solidity
function isNftWhitelisted(
    address licensorIpId,
    address licenseTemplate,
    uint256 licenseTermsId,
    address nftContract
) external view returns (bool);
```

```solidity
function listWhitelistedNfts(
    address licensorIpId,
    address licenseTemplate,
    uint256 licenseTermsId
) external view returns (address[] memory);
```

### Licensing hooks

```solidity
function beforeMintLicenseTokens(
    address caller,
    address licensorIpId,
    address licenseTemplate,
    uint256 licenseTermsId,
    uint256 amount,
    address /* receiver */,
    bytes calldata /* hookData */
) external returns (uint256 totalMintingFee);
```
- Reverts unless `caller` holds ≥1 token from any whitelisted ERC‑721 in scope.
- Returns fee = `amount * mintingFee`, where `mintingFee` comes from the license template’s royalty policy for `licenseTermsId`.

```solidity
function beforeRegisterDerivative(
    address caller,
    address /* childIpId */,
    address parentIpId,
    address licenseTemplate,
    uint256 licenseTermsId,
    bytes calldata /* hookData */
) external returns (uint256 mintingFee);
```
- Gating uses the **parent** IP scope.
- Returns fee for a single unit (amount = 1).

```solidity
function calculateMintingFee(
    address /* caller */,
    address /* licensorIpId */,
    address licenseTemplate,
    uint256 licenseTermsId,
    uint256 amount,
    address /* receiver */,
    bytes calldata /* hookData */
) external view returns (uint256 totalMintingFee);
```
- Pure read of the template’s fee × `amount` (no gating).

### ERC‑165

```solidity
function supportsInterface(bytes4 interfaceId)
    public view override(BaseModule, IERC165) returns (bool);
```

## Events

```solidity
event NftContractWhitelisted(
    address indexed licensorIpId,
    address indexed licenseTemplate,
    uint256 indexed licenseTermsId,
    address nftContract
);

event NftContractRemovedFromWhitelist(
    address indexed licensorIpId,
    address indexed licenseTemplate,
    uint256 indexed licenseTermsId,
    address nftContract
);
```

## Custom errors

- `LicenseNftHolderWhitelistHook_ZeroAddress()`
- `LicenseNftHolderWhitelistHook_NotAttached()`
- `LicenseNftHolderWhitelistHook_AlreadyWhitelisted(address nftContract)`
- `LicenseNftHolderWhitelistHook_NotWhitelisted(address nftContract)`
- `LicenseNftHolderWhitelistHook_CallerNotHolder(address caller)`
- `LicenseNftHolderWhitelistHook_NotContract(address nftContract)`
- `LicenseNftHolderWhitelistHook_NotERC721(address nftContract)`

## Fee calculation

`_calculateFee(licenseTemplate, licenseTermsId, amount)`:
- Reads `(, , mintingFee, ) = ILicenseTemplate.getRoyaltyPolicy(licenseTermsId)`.
- Returns `amount * mintingFee`.
- The hook **does not** manage currency or transfer; it reports the fee expected by the template.

## Integration

1. Deploy the hook with the expected Story Protocol core addresses.
2. In your licensing configuration for a given IP:
    - Set `licensingHook` to the deployed hook address.
    - Ensure the license template/terms are **attached** to the IP via `LICENSE_REGISTRY`.
3. Whitelist one or more ERC‑721 contracts for the scope:
    - Call `addWhitelistNft(licensorIpId, licenseTemplate, licenseTermsId, nftContract)`.
4. Minting/derivative calls will be allowed only if the **caller** holds ≥1 token from any whitelisted contract for that scope.

> Note: This hook checks **caller** holdings. If you need to gate by **receiver**, adapt `_checkNftHolderWhitelist` to use `receiver`.

## Tested behaviors (from the included Foundry tests)

- Add/remove whitelist success and revert paths (already whitelisted, not whitelisted, no permission, zero address, license not attached).
- `isNftWhitelisted` false by default.
- Gating on `beforeMintLicenseTokens` and `beforeRegisterDerivative` succeeds if caller holds any allowed NFT; reverts otherwise.
- Any‑of multiple whitelisted collections is sufficient.
- Fee multiplication by `amount`; `calculateMintingFee` matches the hook’s fee.
- Receiver can differ from caller; gating still checks **caller**.
- Whitelist isolation across different license terms.
- Swap‑and‑pop keeps the list compact.
- After removing the last whitelist entry, minting reverts.

## Security considerations

- Whitelisting checks that `nftContract` is a contract and supports **ERC‑721** via **ERC‑165**; this reduces accidental mis‑configuration.
- Scope includes `ipOwner` to avoid cross‑owner reuse; if IP ownership changes, the scope key changes too.
- Admin functions are permission‑gated by `verifyPermission(licensorIpId)`.

## Compatibility

- Solidity `0.8.26`.
- Uses OpenZeppelin `IERC165`, `IERC721`.
- Integrates with Story Protocol `BaseModule`, `AccessControlled`, `ILicensingHook`, `ILicenseTemplate`, `IIPAccount`, `ILicenseRegistry`.

## License

SPDX‑License‑Identifier: MIT
