{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE LambdaCase #-}

module Socket.Msg
  ( authenticatedMsgLoop
  ) where

import Control.Applicative

import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TChan

import Control.Exception

import Control.Lens
import Control.Monad
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.STM
import Control.Monad.State.Lazy

import Data.Either
import Data.Foldable
import Data.Functor
import Data.Map.Lazy (Map)
import qualified Data.Map.Lazy as M
import Data.Maybe
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as T
import Database.Persist.Postgresql (ConnectionString)
import qualified Network.WebSockets as WS

import Prelude

import Debug.Trace

import Text.Pretty.Simple (pPrint)

import Control.Concurrent.Async
import Poker.ActionValidation
import Poker.Game.Game
import Poker.Game.Utils
import Poker.Poker
import Poker.Types hiding (LeaveSeat)
import Schema
import Socket.Clients
import Socket.Lobby
import Socket.Types
import Socket.Utils
import System.Timeout
import Types

import Database

-- process msgs sent by the client socket
handleReadChanMsgs :: MsgHandlerConfig -> IO ()
handleReadChanMsgs msgHandlerConfig@MsgHandlerConfig {..} =
  forever $ do
    msg <- atomically $ readTChan socketReadChan
    msgOutE <- runExceptT $ runReaderT (gameMsgHandler msg) msgHandlerConfig
    either
      (sendMsg clientConn . ErrMsg)
      (handleNewGameState dbConn serverStateTVar)
      msgOutE
    print "socketReadChannel"
    pPrint msgOutE
    return ()

-- This function writes msgs received from the websocket to the socket threads msgReader channel 
-- then forks a new thread to read msgs from the authenticated client
-- The use of channels in this way makes it feasible to implement timeouts
-- if an expected msg in not received in a given time without killing threads.
-- This is preferable as killing threads inside IO actions is not safe 
authenticatedMsgLoop :: MsgHandlerConfig -> IO ()
authenticatedMsgLoop msgHandlerConfig@MsgHandlerConfig {..} =
  withAsync (handleReadChanMsgs msgHandlerConfig) $ \sockMsgReaderThread ->
    finally
      (catch
         (forever $ do
            msg <- WS.receiveData clientConn
            let parsedMsg = parseMsgFromJSON msg
            for_ parsedMsg $ atomically . writeTChan socketReadChan)
         (\e -> do
            let err = show (e :: IOException)
            print
              ("Warning: Exception occured in authenticatedMsgLoop for " ++
               show username ++ ": " ++ err)
            removeClient username serverStateTVar
            return ()))
      (removeClient username serverStateTVar)

-- takes a channel and if the player in the thread is the current player to act in the room 
-- then if no valid game action is received within 30 secs then we run the Timeout action
-- against the game
tableReceiveMsgLoop :: TableName -> TChan MsgOut -> MsgHandlerConfig -> IO ()
tableReceiveMsgLoop tableName channel msgHandlerConfig@MsgHandlerConfig {..} = do
  msgReaderDup <- atomically $ dupTChan socketReadChan
  dupChan <- atomically $ dupTChan channel
  forever $ do
    chanMsg <- atomically $ readTChan dupChan
    sendMsg clientConn chanMsg
    handleTableMsg msgHandlerConfig chanMsg

handleTableMsg :: MsgHandlerConfig -> MsgOut -> IO ()
handleTableMsg msgHandlerConfig@MsgHandlerConfig {..} (NewGameState tableName game') =
  when
    (isPlayerToAct (unUsername username) game')
    (awaitTimedPlayerAction socketReadChan game' tableName username)
handleTableMsg msgHandlerConfig@MsgHandlerConfig {..} _ = return ()

awaitTimedPlayerAction :: TChan MsgIn -> Game -> TableName -> Username -> IO ()
awaitTimedPlayerAction socketReadChan game tableName username = do
  maybeMsg <-
    awaitValidAction
      game
      tableName
      (unUsername username)
      timeoutDuration
      socketReadChan
  case maybeMsg of
    Nothing ->
      atomically $ writeTChan socketReadChan (GameMove tableName Timeout)
    Just _ -> print maybeMsg
  where
    timeoutDuration = 14000000

-- We duplicate the channel reading the socket msgs and start a timeout
-- The thread will be blocked until either a valid action is received 
-- or the timeout finishes 
--
-- A return value of Nothing denotes that no valid action
-- was received in the given time period.
-- If a valid gameMove player action was received then we
-- wrap the msgIn in a Just
awaitValidAction ::
     Game -> TableName -> PlayerName -> Int -> TChan MsgIn -> IO (Maybe MsgIn)
awaitValidAction game tableName playerName duration socketReadChan = do
  delayTVar <- registerDelay duration
  dupChan <- atomically $ dupTChan socketReadChan
  atomically $
    (Just <$>
     (readTChan dupChan >>= \msg ->
        guard (isValidAction game playerName msg) $> msg)) `orElse`
    (Nothing <$ (readTVar delayTVar >>= check))
  where
    isValidAction game playerName =
      \case
        (GameMove _ action) -> isRight $ validateAction game playerName action
        _ -> False

--- If the game gets to a state where no player action is possible 
--  then we need to recursively progress the game to a state where an action 
--  is possible. The game states which would lead to this scenario where the game 
--  needs to be manually progressed are:
--   
--  1. everyone is all in.
--  1. All but one player has folded or the game. 
--  3. Game is in the Showdown stage.
--
updateGameAndBroadcastT :: TVar ServerState -> TableName -> Game -> STM ()
updateGameAndBroadcastT serverStateTVar tableName newGame = do
  ServerState {..} <- readTVar serverStateTVar
  case M.lookup tableName $ unLobby lobby of
    Nothing -> throwSTM $ TableDoesNotExistEx tableName
    Just table@Table {..} -> do
      writeTChan channel $ NewGameState tableName newGame
      let updatedLobby = updateTableGame tableName newGame lobby
      swapTVar serverStateTVar ServerState {lobby = updatedLobby, ..}
      return ()

handleNewGameState :: ConnectionString -> TVar ServerState -> MsgOut -> IO ()
handleNewGameState connString serverStateTVar (NewGameState tableName newGame) = do
  newServerState <-
    atomically $ updateGameAndBroadcastT serverStateTVar tableName newGame
  progressGame connString serverStateTVar tableName newGame
handleNewGameState _ _ msg = do
  print msg
  return ()

progressGame ::
     ConnectionString -> TVar ServerState -> TableName -> Game -> IO ()
progressGame connString serverStateTVar tableName game@Game {..} =
  when (haveAllPlayersActed game) $ do
    (errE, progressedGame) <- runStateT nextStage game
    pPrint game
    print "haveAllPlayersActed:"
    print (haveAllPlayersActed progressedGame)
    case errE of
      Right () -> do
        atomically $
          updateGameAndBroadcastT serverStateTVar tableName progressedGame
        when
          (progressedGame ^. street == Showdown)
          (dbUpdateUsersChips connString $ getPlayerChipCounts progressedGame)
        pPrint progressedGame
        progressGame connString serverStateTVar tableName progressedGame
      Left err -> print $ "progressGameAlong Err" ++ show err

gameMsgHandler :: MsgIn -> ReaderT MsgHandlerConfig (ExceptT Err IO) MsgOut
gameMsgHandler GetTables {} = getTablesHandler
gameMsgHandler msg@JoinTable {} = undefined
gameMsgHandler msg@TakeSeat {} = takeSeatHandler msg
gameMsgHandler msg@LeaveSeat {} = leaveSeatHandler msg
gameMsgHandler msg@GameMove {} = gameActionHandler msg

getTablesHandler :: ReaderT MsgHandlerConfig (ExceptT Err IO) MsgOut
getTablesHandler = do
  MsgHandlerConfig {..} <- ask
  ServerState {..} <- liftIO $ readTVarIO serverStateTVar
  let tableSummaries = TableList $ summariseTables lobby
  liftIO $ print tableSummaries
  liftIO $ sendMsg clientConn tableSummaries
  return tableSummaries

-- We fork a new thread for each game joined to receive game updates and propagate them to the client
-- We link the new thread to the current thread so on any exception in either then both threads are
-- killed to prevent memory leaks.
takeSeatHandler :: MsgIn -> ReaderT MsgHandlerConfig (ExceptT Err IO) MsgOut
takeSeatHandler move@(TakeSeat tableName chipsToSit) = do
  msgHandlerConfig@MsgHandlerConfig {..} <- ask
  ServerState {..} <- liftIO $ readTVarIO serverStateTVar
  case M.lookup tableName $ unLobby lobby of
    Nothing -> throwError $ TableDoesNotExist tableName
    Just table@Table {..} ->
      if unUsername username `elem` getGamePlayerNames game
        then throwError $ AlreadySatInGame tableName
        else do
          hasEnoughChipsErrE <- canTakeSeat chipsToSit tableName table
          case hasEnoughChipsErrE of
            Left err -> throwError err
            Right () -> do
              let player = getPlayer (unUsername username) chipsToSit
                  takeSeatAction = GameMove tableName $ SitDown player
              (errE, newGame) <-
                liftIO $
                runStateT
                  (runPlayerAction (unUsername username) (SitDown player))
                  game
              case errE of
                Left gameErr -> throwError $ GameErr gameErr
                Right () -> do
                  liftIO $
                    dbDepositChipsIntoPlay
                      dbConn
                      (unUsername username)
                      chipsToSit
                  liftIO $ atomically $ joinTable tableName msgHandlerConfig
                  asyncGameReceiveLoop <-
                    liftIO $
                    async
                      (tableReceiveMsgLoop tableName channel msgHandlerConfig)
                  liftIO $ link asyncGameReceiveLoop
                  liftIO $
                    sendMsg clientConn (SuccessfullySatDown tableName newGame)
                  return $ NewGameState tableName newGame

leaveSeatHandler :: MsgIn -> ReaderT MsgHandlerConfig (ExceptT Err IO) MsgOut
leaveSeatHandler leaveSeatMove@(LeaveSeat tableName) = do
  msgHandlerConfig@MsgHandlerConfig {..} <- ask
  ServerState {..} <- liftIO $ readTVarIO serverStateTVar
  case M.lookup tableName $ unLobby lobby of
    Nothing -> throwError $ TableDoesNotExist tableName
    Just table@Table {..} ->
      if unUsername username `notElem` getGamePlayerNames game
        then throwError $ NotSatInGame tableName
        else do
          (errE, newGame) <-
            liftIO $
            runStateT (runPlayerAction (unUsername username) LeaveSeat') game
          case errE of
            Left gameErr -> throwError $ GameErr gameErr
            Right () -> do
              let maybePlayer =
                    find
                      (\Player {..} -> unUsername username == _playerName)
                      (_players game)
              case maybePlayer of
                Nothing -> throwError $ NotSatInGame tableName
                Just Player {_chips = chipsInPlay, ..} -> do
                  liftIO $
                    dbWithdrawChipsFromPlay
                      dbConn
                      (unUsername username)
                      chipsInPlay
                  liftIO $ sendMsg clientConn (SuccessfullyLeftSeat tableName)
                  return $ NewGameState tableName newGame

canTakeSeat ::
     Int
  -> Text
  -> Table
  -> ReaderT MsgHandlerConfig (ExceptT Err IO) (Either Err ())
canTakeSeat chipsToSit tableName Table {game = Game {..}, ..}
  | chipsToSit >= _minBuyInChips && chipsToSit <= _maxBuyInChips = do
    availableChipsE <- getPlayersAvailableChips
    case availableChipsE of
      Left err -> throwError err
      Right availableChips ->
        if availableChips >= chipsToSit
          then return $ Right ()
          else return $ Left NotEnoughChipsToSit
  | otherwise = return $ Left $ ChipAmountNotWithinBuyInRange tableName

getPlayersAvailableChips ::
     ReaderT MsgHandlerConfig (ExceptT Err IO) (Either Err Int)
getPlayersAvailableChips = do
  MsgHandlerConfig {..} <- ask
  maybeUser <- liftIO $ dbGetUserByUsername dbConn username
  return $
    case maybeUser of
      Nothing -> Left $ UserDoesNotExistInDB (unUsername username)
      Just UserEntity {..} ->
        Right $ userEntityAvailableChips - userEntityChipsInPlay

-- If game is in predeal stage then add player to game else add to waitlist
-- the waitlist is a queue awaiting the next predeal stage of the game
joinTable :: TableName -> MsgHandlerConfig -> STM ()
joinTable tableName MsgHandlerConfig {..} = do
  ServerState {..} <- readTVar serverStateTVar
  let maybeRoom = M.lookup tableName $ unLobby lobby
  case maybeRoom of
    Nothing -> throwSTM $ TableDoesNotExistEx tableName
    Just table@Table {..} ->
      if canJoinGame game
        then do
          let updatedGame = joinGame username chipAmount game
          let updatedTable = Table {game = updatedGame, ..}
          let updatedLobby = updateTable tableName updatedTable lobby
          let tableSubscribers = getTableSubscribers table
          let newServerState = ServerState {lobby = updatedLobby, ..}
          swapTVar serverStateTVar newServerState
        else do
          let updatedTable = joinTableWaitlist username table
          let updatedLobby = updateTable tableName updatedTable lobby
          let newServerState = ServerState {lobby = updatedLobby, ..}
          swapTVar serverStateTVar newServerState
      where gameStage = getGameStage game
            chipAmount = 2500
  return ()

unUsername :: Username -> Text
unUsername (Username username) = username

-- first we check that table exists and player is sat the game at table otherwise we throw an error
-- then the player move is applied to the table which results in either a new game state which is 
-- broadcast to all table subscribers or an error is returned which is then only sent to the
-- originator of the invalid in-game move
gameActionHandler :: MsgIn -> ReaderT MsgHandlerConfig (ExceptT Err IO) MsgOut
gameActionHandler gameMove@(GameMove tableName playerAction) = do
  MsgHandlerConfig {..} <- ask
  ServerState {..} <- liftIO $ readTVarIO serverStateTVar
  case M.lookup tableName $ unLobby lobby of
    Nothing -> throwError $ TableDoesNotExist tableName
    Just table@Table {..} ->
      let satAtTable = unUsername username `elem` getGamePlayerNames game
       in if not satAtTable
            then throwError $ NotSatAtTable tableName
            else do
              (errE, newGame) <-
                liftIO $
                runStateT
                  (runPlayerAction (unUsername username) playerAction)
                  game
              case errE of
                Left gameErr -> throwError $ GameErr gameErr
                Right () -> do
                  liftIO $ pPrint newGame
                  return $ NewGameState tableName newGame