// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import { IIPAssetRegistry } from "@storyprotocol/core/interfaces/registries/IIPAssetRegistry.sol";
import { IPILicenseTemplate } from "@storyprotocol/core/interfaces/modules/licensing/IPILicenseTemplate.sol";
import { ILicensingModule } from "@storyprotocol/core/interfaces/modules/licensing/ILicensingModule.sol";
import { ILicenseToken } from "@storyprotocol/core/interfaces/ILicenseToken.sol";
import { PILFlavors } from "@storyprotocol/core/lib/PILFlavors.sol";
import { Licensing } from "@storyprotocol/core/lib/Licensing.sol";
import { ModuleRegistry } from "@storyprotocol/core/registries/ModuleRegistry.sol";
import { MockERC20 } from "@storyprotocol/test/mocks/token/MockERC20.sol";
import { MockERC721 } from "@storyprotocol/test/mocks/token/MockERC721.sol";

import { LicenseNftHolderWhitelistHook } from "../contracts/LicenseNftHolderWhitelistHook.sol";
import { BaseTest } from "@storyprotocol/periphery/test/utils/BaseTest.t.sol";

// Run this test:
// forge test --fork-url https://aeneid.storyrpc.io/ --match-path test/LicenseNftHolderWhitelistHook.t.sol
contract LicenseNftHolderWhitelistHookTest is BaseTest {
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal charlie = address(0xc4a11e);
    address internal david = address(0xd4a11e);

    // Core contracts (Aeneid testnet)
    IIPAssetRegistry internal IP_ASSET_REGISTRY = IIPAssetRegistry(0x77319B4031e6eF1250907aa00018B8B1c67a244b);
    ILicensingModule internal LICENSING_MODULE   = ILicensingModule(0x04fbd8a2e56dd85CFD5500A4A4DfA955B9f1dE6f);
    IPILicenseTemplate internal PIL_TEMPLATE    = IPILicenseTemplate(0x2E896b0b2Fdb7457499B56AAaA4AE55BCB4Cd316);
    address internal ROYALTY_POLICY_LAP         = 0xBe54FB168b3c982b7AaE60dB6CF75Bd8447b390E;
    address internal ACCESS_CONTROLLER          = 0xcCF37d0a503Ee1D4C11208672e622ed3DFB2275a;
    address internal MODULE_REGISTRY            = 0x022DBAAeA5D8fB31a0Ad793335e39Ced5D631fa5;
    address internal LICENSE_REGISTRY           = 0x529a750E02d8E2f15649c13D69a465286a780e24;
    MockERC20 internal MERC20                   = MockERC20(0xF2104833d386a2734a4eB3B8ad6FC6812F29E38E);

    // Hook under test
    LicenseNftHolderWhitelistHook public HOOK;

    // Test IP (using BaseTest's mockNft as the IP token contract)
    uint256 public tokenId;
    address public ipId;

    // License terms
    uint256 public licenseTermsId;

    // Additional mock NFT collections used for gating
    MockERC721 internal bayc;      // stand-in for BAYC
    MockERC721 internal mayc;      // second collection to test multi-whitelist

    function setUp() public override {
        super.setUp();

        HOOK = new LicenseNftHolderWhitelistHook(
            ACCESS_CONTROLLER,
            address(IP_ASSET_REGISTRY),
            LICENSE_REGISTRY
        );

        // Pretend the hook is registered (as in the original sample)
        vm.mockCall(
            MODULE_REGISTRY,
            abi.encodeWithSelector(ModuleRegistry.isRegistered.selector, address(HOOK)),
            abi.encode(true)
        );

        // Create an IP owned by alice
        tokenId = mockNft.mint(alice);
        ipId = IP_ASSET_REGISTRY.register(block.chainid, address(mockNft), tokenId);

        // Register license terms and attach them to the IP, with our hook configured
        licenseTermsId = PIL_TEMPLATE.registerLicenseTerms(
            PILFlavors.commercialRemix({
                mintingFee: 100, // wei
                commercialRevShare: 0,
                royaltyPolicy: ROYALTY_POLICY_LAP,
                currencyToken: address(MERC20)
            })
        );

        Licensing.LicensingConfig memory cfg = Licensing.LicensingConfig({
            isSet: true,
            mintingFee: 100,
            licensingHook: address(HOOK),
            hookData: "",
            commercialRevShare: 0,
            disabled: false,
            expectMinimumGroupRewardShare: 0,
            expectGroupRewardPool: address(0)
        });

        vm.startPrank(alice);
        LICENSING_MODULE.attachLicenseTerms(ipId, address(PIL_TEMPLATE), licenseTermsId);
        LICENSING_MODULE.setLicensingConfig(ipId, address(PIL_TEMPLATE), licenseTermsId, cfg);
        vm.stopPrank();

        // Deploy mock NFT collections to use as whitelist entries
        bayc = new MockERC721("BAYC");
        mayc = new MockERC721("MAYC");
    }

    /* ─────────────────────────────────────────────────────────────
       Whitelist admin (by NFT contract) 
       ───────────────────────────────────────────────────────────── */

    function test_addWhitelistNft_success() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        assertTrue(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));

        address[] memory list = HOOK.listWhitelistedNfts(ipId, address(PIL_TEMPLATE), licenseTermsId);
        assertEq(list.length, 1);
        assertEq(list[0], address(bayc));
    }

    function test_revert_addWhitelistNft_whenAlreadyWhitelisted() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_AlreadyWhitelisted.selector,
                address(bayc)
            )
        );
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_revert_addWhitelistNft_whenNoPermission() public {
        vm.expectRevert(); // AccessControlled will revert
        vm.prank(bob);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_removeWhitelistNft_success() public {
        vm.startPrank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        vm.stopPrank();

        assertFalse(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));

        address[] memory list = HOOK.listWhitelistedNfts(ipId, address(PIL_TEMPLATE), licenseTermsId);
        assertEq(list.length, 0);
    }

    function test_revert_removeWhitelistNft_whenNotWhitelisted() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_NotWhitelisted.selector,
                address(bayc)
            )
        );
        vm.prank(alice);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_revert_removeWhitelistNft_whenNoPermission() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        vm.expectRevert(); // AccessControlled will revert
        vm.prank(bob);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_isNftWhitelisted_falseByDefault() public {
        assertFalse(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));
    }

    function test_revert_addWhitelistNft_zeroAddress() public {
        vm.expectRevert(
            LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_ZeroAddress.selector
        );
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(0));
    }

    function test_revert_addWhitelistNft_whenLicenseNotAttached() public {
        // New IP with no license terms attached
        uint256 otherTokenId = mockNft.mint(alice);
        address otherIpId = IP_ASSET_REGISTRY.register(block.chainid, address(mockNft), otherTokenId);

        vm.expectRevert(
            LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_NotAttached.selector
        );
        vm.prank(alice);
        HOOK.addWhitelistNft(otherIpId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    /* ─────────────────────────────────────────────────────────────
       Gate checks (caller must hold any whitelisted ERC-721) 
       ───────────────────────────────────────────────────────────── */

    function test_beforeMintLicenseTokens_success_whenCallerHoldsWhitelistedNft() public {
        // Whitelist BAYC and give bob a BAYC token
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        // bob mints; receiver can be anyone (gating is by caller)
        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            charlie,
            ""
        );
        assertEq(fee, 100);
    }

    function test_revert_beforeMintLicenseTokens_whenCallerDoesNotHoldAnyWhitelistedNft() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        // bob does NOT hold BAYC

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_CallerNotHolder.selector,
                bob
            )
        );
        HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            bob,
            ""
        );
    }

    function test_beforeMintLicenseTokens_multipleAmount_feeMultiplies() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            5,
            bob,
            ""
        );
        assertEq(fee, 500); // 5 * 100
    }

    function test_beforeMintLicenseTokens_worksWhenReceiverDiffersFromCaller() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            alice, // receiver different from caller
            ""
        );
        assertEq(fee, 100);
    }

    function test_beforeMintLicenseTokens_anyOfMultipleWhitelistedCollectionsIsEnough() public {
        // Whitelist BAYC and MAYC
        vm.startPrank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(mayc));
        vm.stopPrank();

        // Give bob only MAYC; no BAYC
        mayc.mint(bob);

        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            bob,
            ""
        );
        assertEq(fee, 100);
    }

    function test_whitelistIsolation_acrossDifferentLicenseTerms() public {
        // Second license terms/config
        uint256 licenseTermsId2 = PIL_TEMPLATE.registerLicenseTerms(
            PILFlavors.commercialRemix({
                mintingFee: 200,
                commercialRevShare: 0,
                royaltyPolicy: ROYALTY_POLICY_LAP,
                currencyToken: address(MERC20)
            })
        );
        Licensing.LicensingConfig memory cfg2 = Licensing.LicensingConfig({
            isSet: true,
            mintingFee: 200,
            licensingHook: address(HOOK),
            hookData: "",
            commercialRevShare: 0,
            disabled: false,
            expectMinimumGroupRewardShare: 0,
            expectGroupRewardPool: address(0)
        });

        vm.startPrank(alice);
        LICENSING_MODULE.attachLicenseTerms(ipId, address(PIL_TEMPLATE), licenseTermsId2);
        LICENSING_MODULE.setLicensingConfig(ipId, address(PIL_TEMPLATE), licenseTermsId2, cfg2);
        // Only whitelist BAYC for first license terms
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        vm.stopPrank();

        assertTrue(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));
        assertFalse(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId2, address(bayc)));
    }

    function test_calculateMintingFee_matches_beforeMint_fee() public view {
        uint256 preview = HOOK.calculateMintingFee(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            3,
            bob,
            ""
        );
        assertEq(preview, 300);
    }

    /* ─────────────────────────────────────────────────────────────
       Derivative registration gating (caller must hold whitelisted NFT)
       ───────────────────────────────────────────────────────────── */

    function test_beforeRegisterDerivative_success_whenCallerHoldsWhitelistedNft() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        uint256 fee = 
            HOOK.beforeRegisterDerivative(
                bob,
                address(0), // not used by hook
                ipId,                 // parent IP (the gated one)
                address(PIL_TEMPLATE),
                licenseTermsId,
                ""
            );
        
        assertEq(fee, 100);
    }

    function test_revert_beforeRegisterDerivative_whenCallerDoesNotHoldWhitelistedNft() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        // bob holds nothing

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_CallerNotHolder.selector,
                bob
            )
        );
        
        HOOK.beforeRegisterDerivative(
            bob,
            address(0),
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            ""
        );
    }

    // @notice Check that removal uses swap-and-pop correctly,
    //  This test catches index bookkeeping bugs.
    function test_removeMaintainsCompactList_swapAndPop() public {
        vm.startPrank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(mayc));
        vm.stopPrank();

        // Remove first entry
        vm.prank(alice);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        address[] memory list = HOOK.listWhitelistedNfts(ipId, address(PIL_TEMPLATE), licenseTermsId);
        assertEq(list.length, 1);
        assertEq(list[0], address(mayc));
        assertFalse(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));
        assertTrue(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(mayc)));
    }

    // @notice This test ensures gating re-engages as expected and 
    //  removing the last whitelist entry blocks minting,
    function test_afterRemovingLastWhitelist_mintReverts() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        // Works before removal
        HOOK.beforeMintLicenseTokens(bob, ipId, address(PIL_TEMPLATE), licenseTermsId, 1, bob, "");

        // Remove and expect revert
        vm.prank(alice);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        vm.expectRevert(abi.encodeWithSelector(
            LicenseNftHolderWhitelistHook.LicenseNftHolderWhitelistHook_CallerNotHolder.selector, bob
        ));
        HOOK.beforeMintLicenseTokens(bob, ipId, address(PIL_TEMPLATE), licenseTermsId, 1, bob, "");
    }

}
