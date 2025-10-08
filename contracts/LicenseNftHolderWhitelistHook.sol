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

import {
    LicenseNftHolderWhitelistHook_ZeroAddress,
    LicenseNftHolderWhitelistHook_NotAttached,
    LicenseNftHolderWhitelistHook_InvalidHookData,
    LicenseNftHolderWhitelistHook_AlreadyWhitelisted,
    LicenseNftHolderWhitelistHook_NotWhitelisted,
    LicenseNftHolderWhitelistHook_NotContract,
    LicenseNftHolderWhitelistHook_NotERC721,
    LicenseNftHolderWhitelistHook_CallerNotHolder
} from "../errors/LicenseNftHolderWhitelistHookErrors.sol";

/**
 * @title NFT Holder Gating Hook (flattened whitelist, log-enriched)
 * @notice Gates license minting by requiring the caller to own at least one token from an
 *         ERC-721 contract that has been whitelisted for the scoped license.
 *
 *         Scope factors: current IP owner, licensor IP ID, license template, license terms ID.
 *         Membership key: keccak256(scopeKey, nftContract).
 *
 *         Caller MUST supply the candidate NFT contract via `hookData`:
 *           hookData = abi.encode(address nftContract)
 */
contract LicenseNftHolderWhitelistHook is BaseModule, AccessControlled, ILicensingHook {
    string public constant override name = "LICENSE_NFT_HOLDER_WHITELIST_HOOK";

    ILicenseRegistry public immutable LICENSE_REGISTRY;

    /// @dev Flattened whitelist: (scope + nftContract) => allowed
    mapping(bytes32 => bool) private _whitelisted;

    /* ─────────────────────────────
       Events / Errors
       ───────────────────────────── */

    /**
     * @notice Emitted when an NFT contract is whitelisted for a scope.
     * @param scopeKey          keccak256(ipOwner, licensorIpId, licenseTemplate, licenseTermsId) at emit time
     * @param licensorIpId      licensor IP id
     * @param licenseTemplate   license template address
     * @param licenseTermsId    license terms id
     * @param nftContract       ERC-721 contract address added
     * @param ipOwnerAtWrite    owner of the licensor IP at emit time
     */
    event NftContractWhitelisted(
        bytes32 indexed scopeKey,
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract,
        address ipOwnerAtWrite
    );

    /**
     * @notice Emitted when an NFT contract is removed from a scope whitelist.
     * @param scopeKey          keccak256(ipOwner, licensorIpId, licenseTemplate, licenseTermsId) at emit time
     * @param licensorIpId      licensor IP id
     * @param licenseTemplate   license template address
     * @param licenseTermsId    license terms id
     * @param nftContract       ERC-721 contract address removed
     * @param ipOwnerAtWrite    owner of the licensor IP at emit time
     */
    event NftContractRemovedFromWhitelist(
        bytes32 indexed scopeKey,
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract,
        address ipOwnerAtWrite
    );

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

    /* ─────────────────────────────
       Admin: whitelist management
       ───────────────────────────── */

    /**
     * @notice Add an ERC-721 contract to the whitelist for the scoped license.
     * @dev Only addresses with permission over `licensorIpId` may call.
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

        _assertErc721Contract(nftContract);

        address ipOwnerAtWrite = IIPAccount(payable(licensorIpId)).owner();
        bytes32 scopeKey = keccak256(abi.encodePacked(ipOwnerAtWrite, licensorIpId, licenseTemplate, licenseTermsId));
        bytes32 memberKey = keccak256(abi.encodePacked(scopeKey, nftContract));

        if (_whitelisted[memberKey]) {
            revert LicenseNftHolderWhitelistHook_AlreadyWhitelisted(nftContract);
        }

        _whitelisted[memberKey] = true;

        emit NftContractWhitelisted(
            scopeKey,
            licensorIpId,
            licenseTemplate,
            licenseTermsId,
            nftContract,
            ipOwnerAtWrite
        );
    }

    /**
     * @notice Remove an ERC-721 contract from the whitelist for the scoped license.
     * @dev Only addresses with permission over `licensorIpId` may call.
     */
    function removeWhitelistNft(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract
    ) external verifyPermission(licensorIpId) {
        address ipOwnerAtWrite = IIPAccount(payable(licensorIpId)).owner();
        bytes32 scopeKey = keccak256(abi.encodePacked(ipOwnerAtWrite, licensorIpId, licenseTemplate, licenseTermsId));
        bytes32 memberKey = keccak256(abi.encodePacked(scopeKey, nftContract));

        if (!_whitelisted[memberKey]) {
            revert LicenseNftHolderWhitelistHook_NotWhitelisted(nftContract);
        }

        _whitelisted[memberKey] = false;

        emit NftContractRemovedFromWhitelist(
            scopeKey,
            licensorIpId,
            licenseTemplate,
            licenseTermsId,
            nftContract,
            ipOwnerAtWrite
        );
    }

    /**
     * @notice Check whitelist membership for a specific (scope, nftContract).
     */
    function isNftWhitelisted(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract
    ) external view returns (bool) {
        address ipOwner = IIPAccount(payable(licensorIpId)).owner();
        bytes32 scopeKey = keccak256(abi.encodePacked(ipOwner, licensorIpId, licenseTemplate, licenseTermsId));
        bytes32 memberKey = keccak256(abi.encodePacked(scopeKey, nftContract));
        return _whitelisted[memberKey];
    }

    /* ─────────────────────────────
       Licensing hook logic
       ───────────────────────────── */

    function beforeMintLicenseTokens(
        address caller,
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount,
        address /* receiver */,
        bytes calldata hookData
    ) external returns (uint256 totalMintingFee) {
        address nft = _decodeHookDataNft(hookData);
        _checkNftHolderWhitelist(licensorIpId, licenseTemplate, licenseTermsId, caller, nft);
        return _calculateFee(licenseTemplate, licenseTermsId, amount);
    }

    function beforeRegisterDerivative(
        address caller,
        address /* childIpId */,
        address parentIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        bytes calldata hookData
    ) external returns (uint256 mintingFee) {
        address nft = _decodeHookDataNft(hookData);
        _checkNftHolderWhitelist(parentIpId, licenseTemplate, licenseTermsId, caller, nft);
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

    /* ─────────────────────────────
       Internal utils
       ───────────────────────────── */

    /// @dev Require that `account` owns at least one token from `nft` and that `nft` is whitelisted for the scope.
    function _checkNftHolderWhitelist(
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address account,
        address nft
    ) internal view {
        address ipOwner = IIPAccount(payable(licensorIpId)).owner();
        bytes32 scopeKey = keccak256(abi.encodePacked(ipOwner, licensorIpId, licenseTemplate, licenseTermsId));
        bytes32 memberKey = keccak256(abi.encodePacked(scopeKey, nft));

        if (!_whitelisted[memberKey]) {
            revert LicenseNftHolderWhitelistHook_NotWhitelisted(nft);
        }

        if (IERC721(nft).balanceOf(account) == 0) {
            revert LicenseNftHolderWhitelistHook_CallerNotHolder(account);
        }
    }

    /// @dev Validate target contract is an ERC-721 (ERC-165 probe).
    function _assertErc721Contract(address nftContract) internal view {
        if (nftContract.code.length == 0) {
            revert LicenseNftHolderWhitelistHook_NotContract(nftContract);
        }

        bytes4 iid = type(IERC721).interfaceId;
        (bool ok, bytes memory ret) =
                            nftContract.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, iid));

        bool isSupported = ok && ret.length >= 32 && abi.decode(ret, (bool));
        if (!isSupported) {
            revert LicenseNftHolderWhitelistHook_NotERC721(nftContract);
        }
    }

    /// @dev Decode hookData as abi.encode(address nftContract).
    function _decodeHookDataNft(bytes calldata hookData) internal pure returns (address nft) {
        if (hookData.length != 32) {
            revert LicenseNftHolderWhitelistHook_InvalidHookData();
        }
        nft = abi.decode(hookData, (address));
        if (nft == address(0)) {
            revert LicenseNftHolderWhitelistHook_InvalidHookData();
        }
    }

    /// @dev Pull fee data from the license template.
    function _calculateFee(
        address licenseTemplate,
        uint256 licenseTermsId,
        uint256 amount
    ) internal view returns (uint256 totalMintingFee) {
        (, , uint256 mintingFee, ) = ILicenseTemplate(licenseTemplate).getRoyaltyPolicy(licenseTermsId);
        return amount * mintingFee;
    }
}
