pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

// FantomCollateralStorage<abstract> implements a collateral storage used
// by the Fantom DeFi contract to track collateral accounts
// balances and value.
contract FantomCollateralStorage {
    // define used libs
    using SafeMath for uint256;
    using Address for address;
    using SafeERC20 for ERC20;

    // -------------------------------------------------------------
    // Collateral related state variables by user address
    // -------------------------------------------------------------
    // _collateralTokens tracks user => token => collateral amount relationship
    mapping(address => mapping(address => uint256)) public collateralBalance;

    // _collateralTotalValue keeps track of the total collateral balance
    //  of all the collateral accounts registered in the storage combined
    mapping(address => uint256) public collateralTotalBalance;

    // _collateralTokens represents the list of all collateral tokens
    // registered with the collateral storage.
    address[] public collateralTokens;

    // -------------------------------------------------------------
    // Collateral balance/value calculation
    //
    // We have to use value of the collateral as the virtual token
    // amount since we do not use single token for collateral only.
    // -------------------------------------------------------------

    // tokenValue (abstract) returns the value of the given amount of the token specified.
    function tokenValue(address _token, uint256 _amount) public view returns (uint256);

    // collateralTotal returns the total value of all the collateral tokens
    // registered inside the storage.
    function collateralTotal() public view returns (uint256 value) {
        // loop all registered collateral tokens
        for (uint i = 0; i < collateralTokens.length; i++) {
            // advance the total value by the current collateral balance token value
            value = value.add(tokenValue(collateralTokens[i], collateralTotalBalance[collateralTokens[i]]));
        }

        // return the calculated value
        return value;
    }

    // collateralValueOf returns the current collateral balance of the specified
    // account.
    function collateralValueOf(address _account) public view returns (uint256 value) {
        // loop all registered collateral tokens
        for (uint i = 0; i < collateralTokens.length; i++) {
            // advance the value by the current collateral balance tokens on the account token scanned
            if (0 < collateralBalance[_account][collateralTokens[i]]) {
                value = value.add(tokenValue(collateralTokens[i], collateralBalance[_account][collateralTokens[i]]));
            }
        }

        return value;
    }

    // -------------------------------------------------------------
    // Collateral state update functions
    // -------------------------------------------------------------

    // collateralAdd adds specified amount of tokens to given account
    // collateral and updates the total supply references.
    function collateralAdd(address _account, address _token, uint256 _amount) internal {
        // update the collateral balance of the account
        collateralBalance[_account][_token] = collateralBalance[_account][_token].add(_amount);

        // update the total collateral balance
        collateralTotalBalance[_token] = collateralTotalBalance[_token].add(_amount);

        // make sure the token is registered
        collateralEnrollToken(_token);
    }

    // collateralSub removes specified amount of tokens from given account
    // collateral and updates the total supply references.
    function collateralSub(address _account, address _token, uint256 _amount) internal {
        // update the collateral balance of the account
        collateralBalance[_account][_token] = collateralBalance[_account][_token].sub(_amount);

        // update the total collateral balance
        collateralTotalBalance[_token] = collateralTotalBalance[_token].sub(_amount);
    }

    // -------------------------------------------------------------
    // Collateral related utility functions
    // -------------------------------------------------------------

    // collateralEnrollToken ensures the specified token is in the list
    // of collateral tokens registered with the protocol.
    function collateralEnrollToken(address _token) internal {
        bool found = false;

        // loop the current list and try to find the token
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            if (collateralTokens[i] == _token) {
                found = true;
                break;
            }
        }

        // add the token to the list if not found
        if (!found) {
            collateralTokens.push(_token);
        }
    }

    // collateralTokensCount returns the number of tokens enrolled
    // to the collateral list.
    function collateralTokensCount() public view returns (uint256) {
        // return the current collateral array length
        return collateralTokens.length;
    }
}