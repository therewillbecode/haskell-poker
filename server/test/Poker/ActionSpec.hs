{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Poker.ActionSpec where

import Control.Lens
import Data.Aeson
import Data.Either
import Data.List
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Test.Hspec
import Test.QuickCheck hiding (Big, Small)
import Test.QuickCheck.Arbitrary.Generic
import Test.QuickCheck.Gen

import Arbitrary ()

import Poker.ActionValidation
import Poker.Game.Actions
import Poker.Game.Game
import Poker.Poker
import Poker.Types

player1 =
  Player
    { _pockets = []
    , _chips = 2000
    , _bet = 0
    , _playerState = In
    , _playerName = "player1"
    , _committed = 100
    , _actedThisTurn = True
    }

player2 =
  Player
    { _pockets = []
    , _chips = 2000
    , _bet = 0
    , _playerState = Folded
    , _playerName = "player2"
    , _committed = 50
    , _actedThisTurn = False
    }

player3 =
  Player
    { _pockets = []
    , _chips = 2000
    , _bet = 0
    , _playerState = In
    , _playerName = "player3"
    , _committed = 50
    , _actedThisTurn = False
    }

player4 =
  Player
    { _pockets = []
    , _chips = 2000
    , _bet = 0
    , _playerState = In
    , _playerName = "player3"
    , _committed = 0
    , _actedThisTurn = False
    }

player5 =
  Player
    { _pockets = []
    , _chips = 4000
    , _bet = 4000
    , _playerState = In
    , _playerName = "player5"
    , _committed = 4000
    , _actedThisTurn = True
    }

player6 =
  Player
    { _pockets = []
    , _chips = 2000
    , _bet = 200
    , _playerState = In
    , _playerName = "player6"
    , _committed = 250
    , _actedThisTurn = True
    }

bettingFinishedGame =
  ((players .~ [player1, player2]) . (street .~ PreFlop)) initialGameState

bettingNotFinishedGame =
  ((players .~ [player1, player2, player3, player4]) . (street .~ PreFlop))
    initialGameState

spec = do
  describe "postBlind" $ do
    it "should update player attributes correctly" $ do
      let game =
            (street .~ PreDeal) .
            (players .~ [(committed .~ 0) player1, player3]) $
            initialGameState
          pName = "player1"
          blind = Small
          newGame = postBlind blind pName game
          playerWhoBet = newGame ^? players . ix 0
          smallBlindValue = _smallBlind game
          expectedPlayer =
            Player
              { _pockets = []
              , _chips = 2000 - smallBlindValue
              , _bet = smallBlindValue
              , _playerState = In
              , _playerName = "player1"
              , _committed = smallBlindValue
              , _actedThisTurn = True
              }
      playerWhoBet `shouldBe` Just expectedPlayer
    it "should add blind bet to pot" $ do
      let game =
            (street .~ PreDeal) . (players .~ [player1, player3]) $
            initialGameState
          pName = "player1"
          blind = Small
          newGame = postBlind blind pName game
          playerWhoBet = newGame ^? players . ix 0
      _pot newGame `shouldBe` _smallBlind game
  describe "bet" $ do
    it "should update player attributes correctly" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2, player3]) $
            initialGameState
          betValue = 200
          pName = "player1"
          newGame = makeBet betValue pName game
          playerWhoBet = newGame ^? players . ix 0
          expectedPlayer =
            Player
              { _pockets = []
              , _chips = 2000 - betValue
              , _bet = betValue
              , _playerState = In
              , _playerName = "player1"
              , _committed = 100 + betValue
              , _actedThisTurn = True
              }
      playerWhoBet `shouldBe` Just expectedPlayer
    it "should add bet amount to pot" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2, player3]) $
            initialGameState
          betValue = 200
          pName = "player1"
          newGame = makeBet betValue pName game
      (newGame ^. pot) `shouldBe` betValue
    it "should update maxBet if amount greater than current maxBet" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2, player3]) $
            initialGameState
          betValue = 200
          pName = "player1"
          newGame = makeBet betValue pName game
      (newGame ^. maxBet) `shouldBe` betValue
    it "should update player attributes correctly when bet all in" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2, player3]) $
            initialGameState
          betValue = player1 ^. chips
          pName = "player1"
          newGame = makeBet betValue pName game
          playerWhoBet = newGame ^? players . ix 0
          expectedPlayer =
            Player
              { _pockets = []
              , _chips = 0
              , _bet = betValue
              , _playerState = In
              , _playerName = "player1"
              , _committed = 100 + betValue
              , _actedThisTurn = True
              }
      playerWhoBet `shouldBe` Just expectedPlayer
    it "should increment position to act" $ do
      let game =
            (street .~ PreFlop) . (currentPosToAct .~ 0) .
            (players .~ [player1, player2, player3]) $
            initialGameState
          betValue = 200
          pName = "player1"
          newGame = makeBet betValue pName game
          newPositionToAct = newGame ^. currentPosToAct
          expectedNewPositionToAct = 2
      newPositionToAct `shouldBe` expectedNewPositionToAct
  describe "foldCards" $ do
    it "should update player attributes correctly" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2, player3]) $
            initialGameState
          pName = "player1"
          newGame = foldCards pName game
          playerWhoFolded = newGame ^? players . ix 0
          expectedPlayer =
            Player
              { _pockets = []
              , _chips = 2000
              , _bet = 0
              , _playerState = Folded
              , _playerName = "player1"
              , _committed = 100
              , _actedThisTurn = True
              }
      playerWhoFolded `shouldBe` Just expectedPlayer
    it "should increment position to act" $ do
      let game =
            (street .~ PreFlop) . (currentPosToAct .~ 0) .
            (players .~ [player1, player2, player3]) $
            initialGameState
          pName = "player1"
          newGame = foldCards pName game
          newPositionToAct = newGame ^. currentPosToAct
          expectedNewPositionToAct = 2
      newPositionToAct `shouldBe` expectedNewPositionToAct
  describe "call" $ do
    it "should update player attributes correctly when calling a bet" $ do
      let game =
            (street .~ PreFlop) . (maxBet .~ 400) .
            (players .~ [player1, player6]) $
            initialGameState
          pName = "player6"
          newGame = call pName game
          playerWhoCalled = newGame ^? players . ix 1
          expectedPlayer =
            Player
              { _pockets = []
              , _chips = 1800
              , _bet = 400
              , _playerState = In
              , _playerName = "player6"
              , _committed = 450
              , _actedThisTurn = True
              }
      playerWhoCalled `shouldBe` Just expectedPlayer
    it "should update player attributes correctly when calling AllIn" $ do
      let game' =
            (street .~ PreFlop) . (maxBet .~ 4000) .
            (players .~ [player5, player1]) $
            initialGameState
          pName' = "player1"
          newGame' = call pName' game'
          playerWhoCalled' = newGame' ^? players . ix 1
          expectedPlayer' =
            Player
              { _pockets = []
              , _chips = 0
              , _bet = 2000
              , _playerState = In
              , _playerName = "player1"
              , _committed = 2100
              , _actedThisTurn = True
              }
      playerWhoCalled' `shouldBe` Just expectedPlayer'
    it "should increment position to act" $ do
      let game =
            (street .~ PreFlop) . (currentPosToAct .~ 0) .
            (players .~ [player1, player2, player3]) $
            initialGameState
          pName = "player1"
          newGame = call pName game
          newPositionToAct = newGame ^. currentPosToAct
          expectedNewPositionToAct = 2
      newPositionToAct `shouldBe` expectedNewPositionToAct
  describe "check" $ do
    it "should update player attributes correctly" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2]) $
            initialGameState
          pName = "player1"
          expectedPlayers = [player1, player2, player3]
          newGame = check pName game
          playerWhoChecked = newGame ^? players . ix 0
          expectedPlayer = (actedThisTurn .~ True) player1
      playerWhoChecked `shouldBe` Just expectedPlayer
    it "should increment position to act" $ do
      let game =
            (street .~ PreFlop) . (currentPosToAct .~ 0) .
            (players .~ [player1, player3]) $
            initialGameState
          pName = "player1"
          newGame = check pName game
          newPositionToAct = newGame ^. currentPosToAct
          expectedNewPositionToAct = 1
      newPositionToAct `shouldBe` expectedNewPositionToAct
  describe "incPosToAct" $ do
    it "should modulo increment position for two players who are both In" $ do
      let game =
            (street .~ PreFlop) . (currentPosToAct .~ 0) .
            (players .~ [player1, player3]) $
            initialGameState
      incPosToAct game `shouldBe` 1
      let game2 =
            (street .~ PreFlop) . (currentPosToAct .~ 1) .
            (players .~ [player1, player3]) $
            initialGameState
      incPosToAct game2 `shouldBe` 0
    it "should modulo increment position when one player has folded" $ do
      let game =
            (street .~ PreFlop) . (players .~ [player1, player2, player3]) $
            initialGameState
      incPosToAct game `shouldBe` 2
      let game2 =
            (street .~ PreFlop) . (currentPosToAct .~ 2) .
            (players .~ [player1, player2, player3]) $
            initialGameState
      incPosToAct game2 `shouldBe` 0
    it "should modulo increment position for four players" $ do
      let game =
            (street .~ PreFlop) . (currentPosToAct .~ 2) .
            (players .~ [player1, player4, player3, player2]) $
            initialGameState
      incPosToAct game `shouldBe` 0
      let game2 =
            (street .~ PreFlop) . (currentPosToAct .~ 2) .
            (players .~
             [ player1
             , player4
             , player3
             , (playerState .~ In) player2
             , (playerState .~ In) player2
             ]) $
            initialGameState
      incPosToAct game2 `shouldBe` 3
      let game3 =
            (street .~ PreFlop) . (currentPosToAct .~ 2) .
            (players .~ [player2, player4, player3, player2]) $
            initialGameState
      incPosToAct game3 `shouldBe` 1
  describe "leaveSeat" $ it "should remove player from players list" $ do
    let game =
          (street .~ PreDeal) . (players .~ [player1, player6]) $
          initialGameState
        pName = "player6"
        newGame = leaveSeat pName game
    not (any (\Player {..} -> pName /= _playerName) (_players newGame))