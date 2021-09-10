{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}

module Hydra.TUI where

import Hydra.Prelude hiding (State)

import Brick
import Brick.BChan (newBChan, writeBChan)
import Brick.Forms (Form, FormFieldState, checkboxField, formState, handleFormEvent, newForm, radioField, renderForm)
import Brick.Widgets.Border (hBorder, vBorder)
import Brick.Widgets.Border.Style (ascii)
import Cardano.Ledger.Keys (KeyPair (..))
import Data.List (nub, (!!), (\\))
import qualified Data.Map.Strict as Map
import Data.Version (showVersion)
import Graphics.Vty (Event (EvKey), Key (..), Modifier (..), blue, defaultConfig, green, mkVty, red)
import qualified Graphics.Vty as Vty
import Graphics.Vty.Attributes (defAttr)
import Hydra.Client (Client (Client, sendInput), HydraEvent (..), withClient)
import Hydra.ClientInput (ClientInput (..))
import Hydra.Ledger (Party, Tx (..))
import Hydra.Ledger.Cardano (CardanoAddress, CardanoKeyPair, CardanoTx, TxIn, TxOut, genKeyPair, genUtxoFor, mkSimpleCardanoTx, mkVkAddress, prettyBalance, prettyUtxo)
import Hydra.Network (Host (..))
import Hydra.ServerOutput (ServerOutput (..))
import Hydra.Snapshot (Snapshot (..))
import Hydra.TUI.Options (Options (..))
import Lens.Micro (Lens', lens, (%~), (.~), (?~), (^.), (^?))
import Lens.Micro.TH (makeLensesFor)
import Paths_hydra_tui (version)
import Shelley.Spec.Ledger.API (UTxO (..))
import Test.QuickCheck.Gen (Gen (..), scale)
import Test.QuickCheck.Random (mkQCGen)

--
-- Model
--

data State = State
  { me :: Host
  , peers :: [Host]
  , headState :: HeadState
  , dialogState :: DialogState
  , clientState :: ClientState
  , feedback :: Maybe UserFeedback
  }

data ClientState = Connected | Disconnected

data DialogState where
  NoDialog :: DialogState
  Dialog ::
    forall s e n.
    (n ~ Name, e ~ HydraEvent CardanoTx) =>
    Text ->
    Form s e n ->
    (State -> s -> EventM n (Next State)) ->
    DialogState

data UserFeedback = UserFeedback
  { severity :: Severity
  , message :: Text
  }
  deriving (Eq, Show, Generic)

data Severity
  = Success
  | Info
  | Error
  deriving (Eq, Show, Generic)

severityToAttr :: Severity -> AttrName
severityToAttr = \case
  Success -> positive
  Info -> info
  Error -> negative

info :: AttrName
info = "info"

positive :: AttrName
positive = "positive"

negative :: AttrName
negative = "negative"

data HeadState
  = Unknown
  | Ready
  | Initializing {parties :: [Party], utxo :: Utxo CardanoTx}
  | Open {utxo :: Utxo CardanoTx}
  | Closed {contestationDeadline :: UTCTime}
  | Finalized
  deriving (Eq, Show, Generic)

type Name = Text

makeLensesFor
  [ ("me", "meL")
  , ("peers", "peersL")
  , ("headState", "headStateL")
  , ("clientState", "clientStateL")
  , ("dialogState", "dialogStateL")
  , ("feedback", "feedbackL")
  ]
  ''State

--
-- Update
--

clearFeedback :: State -> State
clearFeedback = feedbackL .~ empty

handleEvent ::
  Client CardanoTx IO ->
  State ->
  BrickEvent Name (HydraEvent CardanoTx) ->
  EventM Name (Next State)
handleEvent client@Client{sendInput} (clearFeedback -> s) = \case
  AppEvent e ->
    continue (handleAppEvent s e)
  VtyEvent e -> case s ^. dialogStateL of
    Dialog title form submit ->
      handleDialogEvent (title, form, submit) s e
    NoDialog -> case e of
      -- Quit
      EvKey (KChar 'c') [MCtrl] -> halt s
      EvKey (KChar 'd') [MCtrl] -> halt s
      EvKey (KChar 'q') _ -> halt s
      -- Commands
      EvKey (KChar 'i') _ ->
        -- TODO(SN): hardcoded contestation period
        liftIO (sendInput $ Init 10) >> continue s
      EvKey (KChar 'a') _ ->
        liftIO (sendInput Abort) >> continue s
      EvKey (KChar 'c') _ ->
        handleCommitEvent client s
      EvKey (KChar 'n') _ ->
        handleNewTxEvent client s
      EvKey (KChar 'C') _ ->
        liftIO (sendInput Close) >> continue s
      _ ->
        continue s
  e ->
    continue $ s & feedbackL ?~ UserFeedback Error ("unhandled event: " <> show e)

handleAppEvent ::
  State ->
  HydraEvent CardanoTx ->
  State
handleAppEvent s = \case
  ClientConnected ->
    s & clientStateL .~ Connected
  ClientDisconnected ->
    s & clientStateL .~ Disconnected
  Update (PeerConnected p) ->
    s & peersL %~ \cp -> nub $ cp <> [p]
  Update (PeerDisconnected p) ->
    s & peersL %~ \cp -> cp \\ [p]
  Update CommandFailed -> do
    s & feedbackL ?~ UserFeedback Error "Invalid command."
  Update ReadyToCommit{parties} ->
    let utxo = mempty
     in s & headStateL .~ Initializing{parties, utxo}
          & feedbackL ?~ UserFeedback Info "Head initialized, ready for commit(s)."
  Update Committed{party, utxo} ->
    s & headStateL %~ partyCommitted party utxo
      & feedbackL ?~ UserFeedback Info (show party <> " committed " <> prettyBalance (balance @CardanoTx utxo))
  Update HeadIsOpen{utxo} ->
    s & headStateL .~ Open{utxo}
      & feedbackL ?~ UserFeedback Info "Head is now open!"
  Update HeadIsClosed{contestationDeadline} ->
    s & headStateL .~ Closed{contestationDeadline}
      & feedbackL ?~ UserFeedback Info "Head closed."
  Update HeadIsFinalized{} ->
    s & headStateL .~ Finalized
      & feedbackL ?~ UserFeedback Info "Head finalized."
  Update TxSeen{} ->
    s
  Update TxInvalid{validationError} ->
    s & feedbackL ?~ UserFeedback Error (show validationError)
  Update TxValid{} ->
    s & feedbackL ?~ UserFeedback Success "Transaction submitted successfully!"
  Update SnapshotConfirmed{snapshot} ->
    snapshotConfirmed snapshot
  Update HeadIsAborted{} ->
    s & headStateL .~ Ready
      & feedbackL ?~ UserFeedback Info "Head aborted, back to square one."
  Update anyUpdate ->
    s & feedbackL ?~ UserFeedback Error ("Unhandled app event: " <> show anyUpdate)
 where
  partyCommitted party commit = \case
    Initializing{parties, utxo} ->
      Initializing
        { parties = parties \\ [party]
        , utxo = utxo <> commit
        }
    hs -> hs

  snapshotConfirmed Snapshot{utxo, number} =
    case s ^? headStateL of
      Just Open{} ->
        s & headStateL .~ Open{utxo}
          & feedbackL ?~ UserFeedback Info ("Snapshot #" <> show number <> " confirmed.")
      _ ->
        s & feedbackL ?~ UserFeedback Error "Snapshot confirmed but head is not open?"

handleDialogEvent ::
  forall s e n.
  (n ~ Name, e ~ HydraEvent CardanoTx) =>
  (Text, Form s e n, State -> s -> EventM n (Next State)) ->
  State ->
  Vty.Event ->
  EventM n (Next State)
handleDialogEvent (title, form, submit) s = \case
  -- NOTE: Field focus is changed using Tab / Shift-Tab, but arrows are more
  -- intuitive, so we forward them. Same for Space <-> Enter
  EvKey KUp [] ->
    handleDialogEvent (title, form, submit) s (EvKey KBackTab [])
  EvKey KDown [] ->
    handleDialogEvent (title, form, submit) s (EvKey (KChar '\t') [])
  EvKey KEnter [] ->
    handleDialogEvent (title, form, submit) s (EvKey (KChar ' ') [])
  EvKey KEsc [] ->
    continue $ s & dialogStateL .~ NoDialog
  EvKey (KChar '>') [] -> do
    submit s (formState form)
  e -> do
    form' <- handleFormEvent (VtyEvent e) form
    continue $ s & dialogStateL .~ Dialog title form' submit

handleCommitEvent ::
  Client CardanoTx IO ->
  State ->
  EventM n (Next State)
handleCommitEvent Client{sendInput} = \case
  s@State{headState = Initializing{}} ->
    continue $ s & dialogStateL .~ newCommitDialog (myTotalUtxo s)
  s ->
    continue $ s & feedbackL ?~ UserFeedback Error "Invalid command."
 where
  newCommitDialog u =
    Dialog title form submit
   where
    title = "Select UTXO to commit"
    form = newForm (utxoCheckboxField u) ((,False) <$> u)
    submit s selected = do
      let commit = UTxO . Map.mapMaybe (\(v, p) -> if p then Just v else Nothing) $ selected
      liftIO (sendInput $ Commit commit)
      continue (s & dialogStateL .~ NoDialog)

handleNewTxEvent ::
  Client CardanoTx IO ->
  State ->
  EventM n (Next State)
handleNewTxEvent Client{sendInput} = \case
  s@State{headState = Open{}} ->
    continue $ s & dialogStateL .~ newTransactionBuilderDialog (myAvailableUtxo s)
  s ->
    continue $ s & feedbackL ?~ UserFeedback Error "Invalid command."
 where
  newTransactionBuilderDialog u =
    Dialog title form submit
   where
    title = "Select UTXO to spend"
    -- FIXME: This crashes if the utxo is empty
    form = newForm (utxoRadioField u) (Map.toList u !! 0)
    submit s input = do
      continue $ s & dialogStateL .~ newRecipientsDialog input (s ^. peersL)

  newRecipientsDialog input peers =
    Dialog title form submit
   where
    title = "Select a recipient"
    -- FIXME: This crashes if peers are empty!
    form =
      let field = radioField (lens id const) [(p, show p, show p) | p <- peers]
       in newForm [field] (peers !! 0)
    submit s (getAddress -> recipient) = do
      liftIO (sendInput (NewTx tx))
      continue $ s & dialogStateL .~ NoDialog
     where
      tx = mkSimpleCardanoTx input recipient (myCredentials s)

--
-- View
--

draw :: State -> [Widget Name]
draw s =
  pure $
    withBorderStyle ascii $
      joinBorders $
        vBox
          [ hBox
              [ drawInfo
              , vBorder
              , drawCommands
              ]
          , hBorder
          , drawErrorMessage
          ]
 where
  drawInfo =
    hLimit 50 $
      vBox $
        mconcat
          [
            [ tuiVersion
            , nodeStatus
            ]
          , drawPeers
          ,
            [ hBorder
            , drawHeadState
            ]
          ]

  tuiVersion = str "Hydra TUI  " <+> withAttr info (str (showVersion version))

  nodeStatus =
    str "Node " <+> case s ^. clientStateL of
      Disconnected -> withAttr negative $ str $ show (s ^. meL)
      Connected -> withAttr positive $ str $ show (s ^. meL)

  drawHeadState = case s ^. clientStateL of
    Disconnected -> emptyWidget
    Connected ->
      case s ^. headStateL of
        Initializing{parties, utxo} ->
          str "Head status: Initializing"
            <=> str ("Total committed: " <> toString (prettyBalance (balance @CardanoTx utxo)))
            <=> str "Waiting for parties to commit:"
            <=> vBox (map drawShow parties)
        Open{utxo} ->
          str "Head status: Open"
            <=> str ("Head balance: " <> toString (prettyBalance (balance @CardanoTx utxo)))
        Closed{contestationDeadline} ->
          str "Head status: Closed"
            <=> str ("Contestation deadline: " <> show contestationDeadline)
        _ ->
          str "Head status: " <+> str (show $ s ^. headStateL)

  drawCommands =
    case s ^? dialogStateL of
      Just (Dialog title form _) ->
        vBox
          [ str (toString title)
          , padTop (Pad 1) $ renderForm form
          , padTop (Pad 1) $
              hBox
                [ padLeft (Pad 5) $ str "[Esc] Cancel"
                , padLeft (Pad 5) $ str "[>] Confirm"
                ]
          ]
      _ ->
        -- TODO: Only show available commands.
        vBox
          [ str "Commands:"
          , str " - [i]nit"
          , str " - [c]ommit"
          , str " - [n]ew transaction"
          , str " - [C]lose"
          , str " - [a]bort"
          , str " - [q]uit"
          ]

  drawErrorMessage =
    case s ^? feedbackL of
      Just (Just UserFeedback{message, severity}) ->
        withAttr (severityToAttr severity) $ str (toString message)
      _ ->
        emptyWidget

  drawPeers =
    case s ^. clientStateL of
      Disconnected ->
        []
      Connected ->
        [ hBorder
        , vBox $ str "Connected peers:" : map drawShow (s ^. peersL)
        ]

  drawShow :: forall a n. Show a => a -> Widget n
  drawShow = str . (" - " <>) . show

--
-- Forms additional widgets
--

-- A helper for creating multiple form fields from a UTXO set.
utxoCheckboxField ::
  forall s e n.
  ( s ~ Map TxIn (TxOut, Bool)
  , n ~ Name
  ) =>
  Map TxIn TxOut ->
  [s -> FormFieldState s e n]
utxoCheckboxField u =
  [ checkboxField
    (checkboxLens k)
    ("checkboxField@" <> show k)
    (prettyUtxo (k, v))
  | (k, v) <- Map.toList u
  ]
 where
  checkboxLens :: Ord k => k -> Lens' (Map k (v, Bool)) Bool
  checkboxLens i =
    lens
      (maybe False snd . Map.lookup i)
      (\s b -> Map.adjust (second (const b)) i s)

-- A helper for creating a radio form fields for selecting a UTXO in a given set
utxoRadioField ::
  forall s e n.
  ( s ~ (TxIn, TxOut)
  , n ~ Name
  ) =>
  Map TxIn TxOut ->
  [s -> FormFieldState s e n]
utxoRadioField u =
  [ radioField
      (lens id const)
      [ (i, show i, prettyUtxo i)
      | i <- Map.toList u
      ]
  ]

-- UTXO Faucet / Credentials
--
-- For now, we _fake it until we make it_ ^TM. Credentials and initial UTXO are
-- generated *deterministically* from the Host (the port number exactly).
-- Ideally, we need the client to figure out credentials and UTXO via some other
-- means. Likely, the credentials will be user-provided, whereas the UTXO would
-- come from a local node + chain sync.

getCredentials :: Host -> CardanoKeyPair
getCredentials Host{port} =
  let seed = fromIntegral port in generateWith genKeyPair seed

getAddress :: Host -> CardanoAddress
getAddress =
  mkVkAddress . vKey . getCredentials

myCredentials :: State -> CardanoKeyPair
myCredentials =
  getCredentials . (^. meL)

myTotalUtxo :: State -> Map TxIn TxOut
myTotalUtxo s =
  let host@Host{port} = s ^. meL
      vk = vKey $ getCredentials host
      UTxO u = generateWith (scale (const 5) $ genUtxoFor vk) (fromIntegral port)
   in u

myAvailableUtxo :: State -> Map TxIn TxOut
myAvailableUtxo s =
  case s ^? headStateL of
    Just Open{utxo = UTxO u'} ->
      let u = myTotalUtxo s in u' `Map.intersection` u
    _ ->
      mempty

generateWith :: Gen a -> Int -> a
generateWith (MkGen runGen) seed =
  runGen (mkQCGen seed) 30

--
-- Run it
--
-- NOTE(SN): At the end of the module because of TH

run :: Options -> IO State
run Options{nodeHost} = do
  eventChan <- newBChan 10
  -- REVIEW(SN): what happens if callback blocks?
  withClient @CardanoTx nodeHost (writeBChan eventChan) $ \client -> do
    initialVty <- buildVty
    customMain initialVty buildVty (Just eventChan) (app client) initialState
 where
  buildVty = mkVty defaultConfig

  app client =
    App
      { appDraw = draw
      , appChooseCursor = showFirstCursor
      , appHandleEvent = handleEvent client
      , appStartEvent = pure
      , appAttrMap = style
      }

  style :: State -> AttrMap
  style _ =
    attrMap
      defAttr
      [ (info, fg blue)
      , (negative, fg red)
      , (positive, fg green)
      ]

  initialState =
    State
      { me = nodeHost
      , peers = mempty
      , headState = Unknown
      , dialogState = NoDialog
      , clientState = Disconnected
      , feedback = empty
      }
