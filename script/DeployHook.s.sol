// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {LicenseNftHolderWhitelistHook} from "../contracts/LicenseNftHolderWhitelistHook.sol";

/// @title DeployHook
/// @notice Foundry script to deploy OwnershipGatedLicenseHook with an empty whitelist.
/// @dev Environment variables:
///  - ACCESS_CONTROLLER  (address) : Story Protocol AccessController
///  - IP_ASSET_REGISTRY  (address) : Story Protocol IPAssetRegistry
///  - LICENSE_REGISTRY   (address) : Story Protocol LicenseRegistry
///
/// PRIVATE KEY HANDLING
///  - If PRIVATE_KEY env var is set (hex or decimal), the script uses vm.startBroadcast(privateKey).
///  - Otherwise, it calls vm.startBroadcast() so you can pass --private-key/--ledger at the CLI.
contract DeployHook is Script {
    function run() external {
        // Required core addresses
        address accessController = vm.envAddress("ACCESS_CONTROLLER");
        address ipAssetRegistry = vm.envAddress("IP_ASSET_REGISTRY");
        address licenseRegistry = vm.envAddress("LICENSE_REGISTRY");

        // Broadcast: prefer PRIVATE_KEY if present; otherwise allow CLI flags
        uint256 deployerKey;
        bool usePk = false;
        try vm.envUint("PRIVATE_KEY") returns (uint256 k) {
            if (k != 0) {
                deployerKey = k;
                usePk = true;
            }
        } catch {
            // no PRIVATE_KEY set
        }

        if (usePk) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast();
        }

        // Deploy using the hook's constructor (accessController, ipAssetRegistry, licenseRegistry)
        LicenseNftHolderWhitelistHook hook =
                    new LicenseNftHolderWhitelistHook(accessController, ipAssetRegistry, licenseRegistry);

        vm.stopBroadcast();

        console2.log("OwnershipGatedLicenseHook deployed at:", address(hook));
        console2.log("AccessController:", accessController);
        console2.log("IPAssetRegistry:", ipAssetRegistry);
        console2.log("LicenseRegistry:", licenseRegistry);
    }
}
