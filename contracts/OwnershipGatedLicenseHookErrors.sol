// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Custom errors used by OwnershipGatedLicenseHook.
// This file is synchronized to match the `revert` sites in
// OwnershipGatedLicenseHook.sol only.

// -------------------------------------------------------------------------
// General / ETH handling
// -------------------------------------------------------------------------
    error EthNotAccepted();
    error ZeroAddress_AdminParams();
    error MaxWhitelistPerContextZero();

// -------------------------------------------------------------------------
// Licensing attachment / validation
// -------------------------------------------------------------------------
    error LicenseNotAttachedToIp(address licensorIpId, address licenseTemplate, uint256 licenseTermsId);

// -------------------------------------------------------------------------
// Whitelist management
// -------------------------------------------------------------------------
    error AlreadyWhitelisted(address licensorIpId, address licenseTemplate, uint256 licenseTermsId, address ipId);
    error NotWhitelisted(address licensorIpId, address licenseTemplate, uint256 licenseTermsId, address ipId);
    error WhitelistFull(address licensorIpId, address licenseTemplate, uint256 licenseTermsId);
    error InvalidIpId_AddWhitelist(address ipId);

// -------------------------------------------------------------------------
// Authorization (ownership) failures
// -------------------------------------------------------------------------
    error NotAuthorized_EmptyWhitelist(address caller);
    error NotAuthorized_All_Missing(address caller, address ipId);
    error NotAuthorized_Any_NoOwnership(address caller, address ipId);
    error NotAuthorized_Any_NoMatch(address caller);
    error NotAuthorized_Any_NftMissing(address caller, address ipId);
