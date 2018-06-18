{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}

module Poker.Types where

import Data.Aeson
import Data.Aeson.Types
import Data.Text
import GHC.Generics

import Control.Lens
import Control.Monad.State hiding (state)
import Data.Function
import Data.Monoid
import Data.Text

------------------------------------------------------------------------------
data Rank
  = Two
  | Three
  | Four
  | Five
  | Six
  | Seven
  | Eight
  | Nine
  | Ten
  | Jack
  | Queen
  | King
  | Ace
  deriving (Eq, Read, Ord, Bounded, Enum, Generic, ToJSON, FromJSON)

instance Show Rank where
  show x =
    case x of
      Two -> "2"
      Three -> "3"
      Four -> "4"
      Five -> "5"
      Six -> "6"
      Seven -> "7"
      Eight -> "8"
      Nine -> "9"
      Ten -> "T"
      Jack -> "J"
      Queen -> "Q"
      King -> "K"
      Ace -> "A"

data Suit
  = Clubs
  | Diamonds
  | Hearts
  | Spades
  deriving (Eq, Ord, Bounded, Enum, Read, Generic, ToJSON, FromJSON)

instance Show Suit where
  show x =
    case x of
      Clubs -> "♧ "
      Diamonds -> "♢ "
      Hearts -> "♡ "
      Spades -> "♤ "

data Card = Card
  { rank :: Rank
  , suit :: Suit
  } deriving (Eq, Read, Generic, ToJSON, FromJSON)

instance Ord Card where
  compare = compare `on` rank

instance Show Card where
  show (Card r s) = show r ++ show s

data HandRank
  = HighCard
  | Pair
  | TwoPair
  | Trips
  | Straight
  | Flush
  | FullHouse
  | Quads
  | StraightFlush
  deriving (Eq, Ord, Show, Read, Generic, ToJSON, FromJSON)

type Bet = Int

data Out
  = Folded
  | AllIn
  deriving (Eq, Show, Ord, Read, Generic, ToJSON, FromJSON)

data PlayerState
  = None -- none denotes a player that will not be dealt cards unless they send a postblinds action to the server
  | Out Out
  | In
  deriving (Eq, Show, Ord, Read, Generic, ToJSON, FromJSON)

data Street
  = PreDeal
  | PreFlop
  | Flop
  | Turn
  | River
  | Showdown
  deriving (Eq, Ord, Show, Read, Bounded, Enum, Generic, ToJSON, FromJSON)

data Player = Player
  { _pockets :: [Card]
  , _chips :: Int
  , _bet :: Bet
  , _playerState :: PlayerState
  , _playerName :: Text
  , _committed :: Bet
  , _actedThisTurn :: Bool
  } deriving (Show, Eq, Read, Ord, Generic, ToJSON, FromJSON)

data Game = Game
  { _players :: [Player]
  , _maxPlayers :: Int
  , _board :: [Card]
  , _winners :: [((HandRank, [Card]), Player)]
  , _waitlist :: [Text] --playernames
  , _deck :: [Card]
  , _smallBlind :: Int
  , _bigBlind :: Int
  , _street :: Street
  , _pot :: Int
  , _maxBet :: Bet
  , _dealer :: Int
  , _currentPosToAct :: Int -- position here refes to the zero indexed set of active users
  } deriving (Eq, Read, Ord, Generic, ToJSON, FromJSON)

instance Show Game where
  show Game {..} =
    show _players <> show _board <> "\n dealer: " <> show _dealer <>
    "\n _currentPosToAct: " <>
    show _currentPosToAct <>
    "\n _street: " <>
    show _street

type PlayerName = Text

data Blind
  = Small
  | Big
  deriving (Show, Eq, Read, Ord, Generic, ToJSON, FromJSON)

-- If you can check, that is you aren't facing an amount you have to call, 
-- then when you put in chips it is called a bet. If you have to put in
-- some amount of chips to continue with the hand, and you want to 
-- increase the pot, it's called a raise. If it is confusing, just remember 
-- this old poker adage: "You can't raise yourself."
data PlayerAction
  = SitDown Player -- doesnt progress the game
  | LeaveSeat -- doesnt progress the game
  | PostBlind Blind
  | Fold
  | Call
  | Raise Int
  | Check
  | Bet Int
  deriving (Show, Eq, Read, Ord, Generic, ToJSON, FromJSON)

data GameErr
  = NotEnoughChips PlayerName
  | PlayerNotAtTable PlayerName
  | AlreadySatAtTable PlayerName
  | NotAtTable PlayerName
  | InvalidMove PlayerName
                InvalidMoveErr
  deriving (Show, Eq, Read, Ord, Generic, ToJSON, FromJSON)

-- if player takes an invalid move we need to inform the client and include the reason why
data InvalidMoveErr
  = BlindNotRequired
  | BlindRequired Blind
  | NoBlindRequired
  | BlindAlreadyPosted Blind
  | OutOfTurn CurrentPlayerToActErr
  | CannotPostBlindOutsidePreDeal
  | InvalidActionForStreet
  | BetLessThanBigBlind
  | NotEnoughChipsForAction
  | CannotBetShouldRaiseInstead
  | PlayerToActNotAtTable
  | CannotRaiseShouldBetInstead
  | RaiseAmountBelowMinRaise Int
  | CannotCheckShouldCallRaiseOrFold
  | CannotCallZeroAmountCheckOrBetInstead
  deriving (Show, Eq, Read, Ord, Generic, ToJSON, FromJSON)

newtype CurrentPlayerToActErr =
  CurrentPlayerToActErr PlayerName
  deriving (Show, Eq, Read, Ord, Generic, ToJSON, FromJSON)

makeLenses ''Player

makeLenses ''Game