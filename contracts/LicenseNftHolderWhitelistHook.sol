// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IERC721 } from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import { BaseModule } from "@storyprotocol/core/modules/BaseModule.sol";
import { AccessControlled } from "@storyprotocol/core/access/AccessControlled.sol";
import { ILicensingHook } from "@storyprotocol/core/interfaces/modules/licensing/ILicensingHook.sol";
import { ILicenseTemplate } from "@storyprotocol/core/interfaces/modules/licensing/ILicenseTemplate.sol";
import { IIPAccount } from "@storyprotocol/core/interfaces/IIPAccount.sol";
import { ILicenseRegistry } from "@storyprotocol/core/interfaces/registries/ILicenseRegistry.sol";

/**
 * @title NFT Holder Gating Hook
 * @notice Gates license minting by requiring the caller to currently own at least
 *         one ERC-721 token from ANY NFT contract whitelisted for the given license.
 *
 *         Scoping of the whitelist mirrors the official sample:
 *         key = keccak256(ipOwner, licensorIpId, licenseTemplate, licenseTermsId).
 *
 *         To use this hook, set the `licensingHook` field in the licensing config
 *         to the deployed address of this contract.
 *
 * @dev This hook checks the CALLER's NFT holdings (not the receiver's).
 *      If you need to gate by receiver, adapt `_checkNftHolderWhitelist` to
 *      use `receiver` instead of `caller`.
 */
contract LicenseNftHolderWhitelistHook is BaseModule, AccessControlled, ILicensingHook {
    /// @dev Human-readable module name.
    string public constant override name = "LICENSE_NFT_HOLDER_WHITELIST_HOOK";

    /// @dev Story Protocol LicenseRegistry for "license attached" validation.
    ILicenseRegistry public immutable LICENSE_REGISTRY;

    /**
     * @notice For each scoped license key, track NFT contracts that are allowed.
     *         `whitelistedNfts[key][nftContract] == true` means the contract is allowed.
     */
    mapping(bytes32 => mapping(address => bool)) private whitelistedNfts;

    /**
     * @notice Optional enumerable storage (per key) to iterate whitelisted contracts.
     *         Useful for offchain tooling and `view` helpers.
     */
    mapping(bytes32 => address[]) private whitelistedNftList;

    /**
     * @notice Keep an index for O(1) removal from the list (swap & pop).
     *         1-based indexing so 0 means "absent".
     */
    mapping(bytes32 => mapping(address => uint256)) private nftIndex1Based;

    /* *************************
     *           Events
     * *************************/
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

    /* *************************
     *          Errors
     * *************************/
    error LicenseNftHolderWhitelistHook_ZeroAddress();
    error LicenseNftHolderWhitelistHook_NotAttached();
    error LicenseNftHolderWhitelistHook_AlreadyWhitelisted(address nftContract);
    error LicenseNftHolderWhitelistHook_NotWhitelisted(address nftContract);
    error LicenseNftHolderWhitelistHook_CallerNotHolder(address caller);
    error LicenseNftHolderWhitelistHook_NotContract(address nftContract);
    error LicenseNftHolderWhitelistHook_NotERC721(address nftContract);
    
    /* *************************
     *        Construction
     * *************************/
    constructor(
        address accessController,
        address ipAssetRegistry,
        address licenseRegistry
    ) AccessControlled(accessController, ipAssetRegistry) {
        if (licenseRegistry == address(0)) {
            revert LicenseNftHolderWhitelistHook_ZeroAddress();
        }
        LICENSE_REGISTRY = ILicenseRegistry(licenseRegistry);
    }

    /// @dev Validate that `nftContract` is a deployed contract that reports ERC-721 support via ERC-165.
    function _assertErc721Contract(address nftContract) internal view {
        // must be a contract
        if (nftContract.code.length == 0) {
            revert LicenseNftHolderWhitelistHook_NotContract(nftContract);
        }

        // ERC-165 supportsInterface(ERC721)
        bytes4 iid = type(IERC721).interfaceId;
        (bool ok, bytes memory ret) =
                            nftContract.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, iid));

        bool isSupported = ok && ret.length >= 32 && abi.decode(ret, (bool));
        if (!isSupported) {
            revert LicenseNftHolderWhitelistHook_NotERC721(nftContract);
        }
    }

    /* *************************
     *     Admin: whitelist mgmt
     * *************************/

    /**
     * @notice Add an NFT contract to the whitelist for a specific license scope.
     * @dev Only an address with permission over `licensorIpId` may call.
     */
    function addWhitelistNft(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract
    ) external verifyPermission(licensorIpId) {
        if (
            !LICENSE_REGISTRY.hasIpAttachedLicenseTerms(
            licensorIpId,
            licenseTemplate,
            licenseTermsId
        )
        ) {
            revert LicenseNftHolderWhitelistHook_NotAttached();
        }

        if (nftContract == address(0)) {
            revert LicenseNftHolderWhitelistHook_ZeroAddress();
        }

        // NEW: validate target is an ERC-721 contract (ERC-165 probe)
        _assertErc721Contract(nftContract);

        bytes32 key = _scopeKey(licensorIpId, licenseTemplate, licenseTermsId);

        if (whitelistedNfts[key][nftContract]) {
            revert LicenseNftHolderWhitelistHook_AlreadyWhitelisted(nftContract);
        }

        whitelistedNfts[key][nftContract] = true;
        whitelistedNftList[key].push(nftContract);
        nftIndex1Based[key][nftContract] = whitelistedNftList[key].length; // 1-based

        emit NftContractWhitelisted(licensorIpId, licenseTemplate, licenseTermsId, nftContract);
    }

    /**
     * @notice Remove an NFT contract from the whitelist for a specific license scope.
     * @dev Only an address with permission over `licensorIpId` may call.
     */
    function removeWhitelistNft(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract
    ) external verifyPermission(licensorIpId) {
        bytes32 key = _scopeKey(licensorIpId, licenseTemplate, licenseTermsId);

        if (!whitelistedNfts[key][nftContract]) {
            revert LicenseNftHolderWhitelistHook_NotWhitelisted(nftContract);
        }

        // delete mapping flag
        whitelistedNfts[key][nftContract] = false;

        // swap & pop from the list using the index map
        uint256 idx1 = nftIndex1Based[key][nftContract];
        uint256 last = whitelistedNftList[key].length;

        if (idx1 != last) {
            address lastAddr = whitelistedNftList[key][last - 1];
            whitelistedNftList[key][idx1 - 1] = lastAddr;
            nftIndex1Based[key][lastAddr] = idx1;
        }
        whitelistedNftList[key].pop();
        nftIndex1Based[key][nftContract] = 0;

        emit NftContractRemovedFromWhitelist(licensorIpId, licenseTemplate, licenseTermsId, nftContract);
    }

    /* *************************
     *         View helpers
     * *************************/

    /**
     * @notice Check if an NFT contract is whitelisted for a given scope.
     */
    function isNftWhitelisted(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract
    ) external view returns (bool) {
        bytes32 key = _scopeKey(licensorIpId, licenseTemplate, licenseTermsId);
        return whitelistedNfts[key][nftContract];
    }

    /**
     * @notice Return the full list of whitelisted NFT contracts for a given scope.
     * @dev For offchain consumption; onchain callers should avoid large unbounded arrays.
     */
    function listWhitelistedNfts(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId
    ) external view returns (address[] memory) {
        bytes32 key = _scopeKey(licensorIpId, licenseTemplate, licenseTermsId);
        return whitelistedNftList[key];
    }

    /* *************************
     *     Licensing hook logic
     * *************************/

    function beforeMintLicenseTokens(
        address caller,
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount,
        address /* receiver */,
        bytes calldata /* hookData */
    ) external returns (uint256 totalMintingFee) {
        _checkNftHolderWhitelist(licensorIpId, licenseTemplate, licenseTermsId, caller);
        return _calculateFee(licenseTemplate, licenseTermsId, amount);
    }

    function beforeRegisterDerivative(
        address caller,
        address /* childIpId */,
        address parentIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        bytes calldata /* hookData */
    ) external returns (uint256 mintingFee) {
        _checkNftHolderWhitelist(parentIpId, licenseTemplate, licenseTermsId, caller);
        return _calculateFee(licenseTemplate, licenseTermsId, 1);
    }

    function calculateMintingFee(
        address /* caller */,
        address /* licensorIpId */,
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount,
        address /* receiver */,
        bytes calldata /* hookData */
    ) external view returns (uint256 totalMintingFee) {
        return _calculateFee(licenseTemplate, licenseTermsId, amount);
    }

    function supportsInterface(bytes4 interfaceId)
    public
    view
    virtual
    override (BaseModule, IERC165)
    returns (bool)
    {
        return interfaceId == type(ILicensingHook).interfaceId || super.supportsInterface(interfaceId);
    }

    /* *************************
     *        Internal utils
     * *************************/

    /// @dev Build the scoping key using current IP owner so ownership change resets scope.
    function _scopeKey(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId
    ) internal view returns (bytes32) {
        address ipOwner = IIPAccount(payable(licensorIpId)).owner();
        return keccak256(abi.encodePacked(ipOwner, licensorIpId, licenseTemplate, licenseTermsId));
    }

    /// @dev Revert unless `account` owns at least one token from any whitelisted ERC-721 in scope.
    function _checkNftHolderWhitelist(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address account
    ) internal view {
        bytes32 key = _scopeKey(licensorIpId, licenseTemplate, licenseTermsId);

        address[] memory list = whitelistedNftList[key];
        uint256 len = list.length;

        bool eligible = false;

        // Require at least one NFT contract to be whitelisted and held by caller.
        for (uint256 i = 0; i < len; i++) {
            address nft = list[i];
            if (whitelistedNfts[key][nft]) {
                // Try-catch not needed for standard ERC-721; if the target doesn't implement,
                // this will revert, which is acceptable (treat as not eligible).
                if (IERC721(nft).balanceOf(account) > 0) {
                    eligible = true;
                    break;
                }
            }
        }

        if (!eligible) {
            revert LicenseNftHolderWhitelistHook_CallerNotHolder(account);
        }
    }

    /// @dev Mirror of the sample: pull minting fee from the license template.
    function _calculateFee(
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount
    ) internal view returns (uint256 totalMintingFee) {
        (, , uint256 mintingFee, ) = ILicenseTemplate(licenseTemplate).getRoyaltyPolicy(licenseTermsId);
        return amount * mintingFee;
    }
}
