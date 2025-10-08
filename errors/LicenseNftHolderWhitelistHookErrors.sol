// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Custom errors used by LicenseNftHolderWhitelistHook.
// This file mirrors the revert sites in LicenseNftHolderWhitelistHook.sol only.
// If you decide to import this file from the contract, remove the inline
// error declarations from the contract to avoid duplicate definitions.

// -------------------------------------------------------------------------
// Licensing attachment / validation
// -------------------------------------------------------------------------
    error LicenseNftHolderWhitelistHook_ZeroAddress();
    error LicenseNftHolderWhitelistHook_NotAttached();
    error LicenseNftHolderWhitelistHook_InvalidHookData();

// -------------------------------------------------------------------------
// Whitelist management
// -------------------------------------------------------------------------
    error LicenseNftHolderWhitelistHook_AlreadyWhitelisted(address nftContract);
    error LicenseNftHolderWhitelistHook_NotWhitelisted(address nftContract);

// -------------------------------------------------------------------------
// Target contract validation (ERC-721 via ERC-165)
// -------------------------------------------------------------------------
    error LicenseNftHolderWhitelistHook_NotContract(address nftContract);
    error LicenseNftHolderWhitelistHook_NotERC721(address nftContract);

// -------------------------------------------------------------------------
// Authorization (caller must hold a token from the candidate NFT)
// -------------------------------------------------------------------------
    error LicenseNftHolderWhitelistHook_CallerNotHolder(address caller);
