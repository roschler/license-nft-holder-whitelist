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

import { BaseTest } from "@storyprotocol/periphery/test/utils/BaseTest.t.sol";

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

import {LicenseNftHolderWhitelistHook} from "../contracts/LicenseNftHolderWhitelistHook.sol";

/**
 * Run with Aeneid fork (uses live protocol addresses):
 *   forge test --fork-url https://aeneid.storyrpc.io/ --match-path test/LicenseNftHolderWhitelistHookTest.t.sol
 */
contract LicenseNftHolderWhitelistHookTest is BaseTest {
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    address internal charlie = address(0xc4a11e);

    // Core contracts (Aeneid)
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

    // Mock NFT collections used for gating
    MockERC721 internal bayc;      // stand-in for BAYC
    MockERC721 internal mayc;      // second collection

    // Re-declare events for expectEmit matching (same signature as contract)
    event NftContractWhitelisted(
        bytes32 indexed scopeKey,
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract,
        address ipOwnerAtWrite
    );
    event NftContractRemovedFromWhitelist(
        bytes32 indexed scopeKey,
        address licensorIpId,
        address licenseTemplate,
        uint256 licenseTermsId,
        address nftContract,
        address ipOwnerAtWrite
    );

    function setUp() public override {
        super.setUp();

        HOOK = new LicenseNftHolderWhitelistHook(
            ACCESS_CONTROLLER,
            address(IP_ASSET_REGISTRY),
            LICENSE_REGISTRY
        );

        // Pretend the hook is registered (mocks ModuleRegistry.isRegistered)
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
            hookData: "", // per-call hookData supplies the NFT; config-level can stay empty
            commercialRevShare: 0,
            disabled: false,
            expectMinimumGroupRewardShare: 0,
            expectGroupRewardPool: address(0)
        });

        vm.startPrank(alice);
        LICENSING_MODULE.attachLicenseTerms(ipId, address(PIL_TEMPLATE), licenseTermsId);
        LICENSING_MODULE.setLicensingConfig(ipId, address(PIL_TEMPLATE), licenseTermsId, cfg);
        vm.stopPrank();

        // Deploy mock NFT collections
        bayc = new MockERC721("BAYC");
        mayc = new MockERC721("MAYC");
    }

    /* ─────────────────────────────────────────────────────────────
       Admin: whitelist management (flattened mapping; enriched events)
       ───────────────────────────────────────────────────────────── */

    function test_addWhitelistNft_emits_enriched_event() public {
        address ownerAtWrite = mockIpOwner();
        bytes32 expectedScope = keccak256(abi.encodePacked(ownerAtWrite, ipId, address(PIL_TEMPLATE), licenseTermsId));

        vm.expectEmit(true, true, true, true);
        emit NftContractWhitelisted(
            expectedScope,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            address(bayc),
            ownerAtWrite
        );

        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        // point lookup still available
        assertTrue(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));
    }

    function test_removeWhitelistNft_emits_enriched_event() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        address ownerAtWrite = mockIpOwner();
        bytes32 expectedScope = keccak256(abi.encodePacked(ownerAtWrite, ipId, address(PIL_TEMPLATE), licenseTermsId));

        vm.expectEmit(true, true, true, true);
        emit NftContractRemovedFromWhitelist(
            expectedScope,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            address(bayc),
            ownerAtWrite
        );

        vm.prank(alice);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        assertFalse(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));
    }

    function test_revert_addWhitelistNft_whenAlreadyWhitelisted() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_AlreadyWhitelisted.selector,
                address(bayc)
            )
        );
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_revert_addWhitelistNft_whenNoPermission() public {
        vm.expectRevert(); // AccessControlled revert
        vm.prank(bob);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_revert_addWhitelistNft_zeroAddress() public {
        vm.expectRevert(LicenseNftHolderWhitelistHook_ZeroAddress.selector);
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(0));
    }

    function test_revert_addWhitelistNft_notAttached() public {
        // New IP with no license terms attached
        uint256 otherTokenId = mockNft.mint(alice);
        address otherIpId = IP_ASSET_REGISTRY.register(block.chainid, address(mockNft), otherTokenId);

        vm.expectRevert(LicenseNftHolderWhitelistHook_NotAttached.selector);
        vm.prank(alice);
        HOOK.addWhitelistNft(otherIpId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_revert_addWhitelistNft_notContract() public {
        // EOAs have empty code; should revert
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_NotContract.selector,
                bob
            )
        );
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, bob);
    }

    function test_revert_addWhitelistNft_notERC721() public {
        // MERC20 is a contract but not ERC721 (no ERC165 support for the 721 interface)
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_NotERC721.selector,
                address(MERC20)
            )
        );
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(MERC20));
    }

    function test_revert_removeWhitelistNft_whenNotWhitelisted() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_NotWhitelisted.selector,
                address(bayc)
            )
        );
        vm.prank(alice);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_revert_removeWhitelistNft_whenNoPermission() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));

        vm.expectRevert(); // AccessControlled revert
        vm.prank(bob);
        HOOK.removeWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
    }

    function test_isNftWhitelisted_falseByDefault() public {
        assertFalse(HOOK.isNftWhitelisted(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc)));
    }

    /* ─────────────────────────────────────────────────────────────
       Gating: candidate NFT must be supplied via hookData and owned by caller
       ───────────────────────────────────────────────────────────── */

    function test_beforeMint_success_whenCallerHoldsWhitelistedNft() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            charlie,
            abi.encode(address(bayc))
        );
        assertEq(fee, 100);
    }

    function test_beforeMint_multipleAmount_feeMultiplies() public {
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
            abi.encode(address(bayc))
        );
        assertEq(fee, 500); // 5 * 100
    }

    function test_beforeMint_anyOfMultipleWhitelistedCollections_isEnough_whenProvided() public {
        vm.startPrank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(mayc));
        vm.stopPrank();

        mayc.mint(bob);

        // Caller supplies MAYC in hookData; succeeds even without BAYC
        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            bob,
            abi.encode(address(mayc))
        );
        assertEq(fee, 100);
    }

    function test_revert_beforeMint_whenCandidateNotOwned() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        // bob does not own BAYC

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_CallerNotHolder.selector,
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
            abi.encode(address(bayc))
        );
    }

    function test_revert_beforeMint_whenCandidateNotWhitelisted() public {
        // bob owns MAYC, but MAYC not whitelisted
        mayc.mint(bob);

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_NotWhitelisted.selector,
                address(mayc)
            )
        );
        HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            bob,
            abi.encode(address(mayc))
        );
    }

    function test_revert_beforeMint_whenHookDataInvalid() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        // Empty hookData should revert
        vm.expectRevert(LicenseNftHolderWhitelistHook_InvalidHookData.selector);
        HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            bob,
            bytes("")
        );
    }

    function test_beforeMint_receiverCanDifferFromCaller() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        uint256 fee = HOOK.beforeMintLicenseTokens(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            1,
            alice, // receiver
            abi.encode(address(bayc))
        );
        assertEq(fee, 100);
    }

    function test_calculateMintingFee_matches_beforeMint_fee() public view {
        uint256 preview = HOOK.calculateMintingFee(
            bob,
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            3,
            bob,
            abi.encode(address(bayc))
        );
        assertEq(preview, 300);
    }

    /* ─────────────────────────────────────────────────────────────
       Derivative registration gating (uses same candidate NFT via hookData)
       ───────────────────────────────────────────────────────────── */

    function test_beforeRegisterDerivative_success_whenCallerHoldsWhitelistedNft() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        uint256 fee = HOOK.beforeRegisterDerivative(
            bob,
            address(0), // childIpId unused
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            abi.encode(address(bayc))
        );
        assertEq(fee, 100);
    }

    function test_revert_beforeRegisterDerivative_whenCandidateNotOwned() public {
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        // bob does not own BAYC

        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_CallerNotHolder.selector,
                bob
            )
        );
        HOOK.beforeRegisterDerivative(
            bob,
            address(0),
            ipId,
            address(PIL_TEMPLATE),
            licenseTermsId,
            abi.encode(address(bayc))
        );
    }

    /* ─────────────────────────────────────────────────────────────
       Ownership change: scope key changes; prior whitelist entries no longer apply
       ───────────────────────────────────────────────────────────── */

    function test_scopeResets_onIpOwnershipTransfer() public {
        // Whitelist BAYC under Alice's ownership and give bob BAYC
        vm.prank(alice);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        bayc.mint(bob);

        // Works while Alice owns the IP
        HOOK.beforeMintLicenseTokens(
            bob, ipId, address(PIL_TEMPLATE), licenseTermsId, 1, bob, abi.encode(address(bayc))
        );

        // Transfer underlying IP NFT to bob (owner changes -> scope key changes)
        vm.prank(alice);
        mockNft.transferFrom(alice, bob, tokenId);

        // Old whitelist entry should no longer apply (now not whitelisted under new owner)
        vm.expectRevert(
            abi.encodeWithSelector(
                LicenseNftHolderWhitelistHook_NotWhitelisted.selector,
                address(bayc)
            )
        );
        HOOK.beforeMintLicenseTokens(
            bob, ipId, address(PIL_TEMPLATE), licenseTermsId, 1, bob, abi.encode(address(bayc))
        );

        // New owner can re-whitelist and proceed
        vm.prank(bob);
        HOOK.addWhitelistNft(ipId, address(PIL_TEMPLATE), licenseTermsId, address(bayc));
        HOOK.beforeMintLicenseTokens(
            bob, ipId, address(PIL_TEMPLATE), licenseTermsId, 1, bob, abi.encode(address(bayc))
        );
    }

    /* ─────────────────────────────────────────────────────────────
       Helpers
       ───────────────────────────────────────────────────────────── */

    function mockIpOwner() internal view returns (address) {
        // IIPAccount(payable(ipId)).owner() would also work, but we know alice owns at setUp time
        // Read via the same logic the hook uses to avoid surprises
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory data) =
                            ipId.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && data.length == 32, "owner() failed");
        return abi.decode(data, (address));
    }
}
