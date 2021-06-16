{-# LANGUAGE TypeApplications #-}

module Hydra.HeadLogicSpec where

import Cardano.Prelude

import Control.Monad.Fail (
  fail,
 )
import qualified Data.Set as Set
import Hydra.HeadLogic (
  ClientResponse (PeerConnected),
  Effect (ClientEffect),
  Environment (..),
  Event (..),
  HeadParameters (..),
  HeadState (..),
  HeadStatus (..),
  HydraMessage (..),
  OnChainTx (..),
  Outcome (..),
  SimpleHeadState (..),
  Snapshot (..),
  SnapshotStrategy (..),
  update,
 )
import Hydra.Ledger (Ledger (..), ParticipationToken (..), Party, Tx)
import Hydra.Ledger.Mock (MockTx (ValidTx), mockLedger)
import Test.Hspec (
  Spec,
  describe,
  expectationFailure,
  it,
  shouldBe,
 )
import Test.Hspec.Core.Spec (pending)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, Property, elements, forAll)
import Test.QuickCheck.Instances.Time ()
import Test.QuickCheck.Property (collect)

spec :: Spec
spec = describe "Hydra Head Logic" $ do
  let threeParties = Set.fromList [1, 2, 3]
      ledger = mockLedger
      env =
        Environment
          { party = 2
          , snapshotStrategy = NoSnapshots
          }

  it "confirms tx given it receives AckTx from all parties" $ do
    let reqTx = NetworkEvent $ ReqTx (ValidTx 1)
        ackFrom n = NetworkEvent $ AckTx n (ValidTx 1)
        s0 = initialState threeParties ledger

    s1 <- assertNewState $ update env ledger s0 reqTx
    s2 <- assertNewState $ update env ledger s1 (ackFrom 3)
    s3 <- assertNewState $ update env ledger s2 (ackFrom 1)
    getConfirmedTransactions s3 `shouldBe` []

    s4 <- assertNewState $ update env ledger s3 (ackFrom 2)
    getConfirmedTransactions s4 `shouldBe` [ValidTx 1]

  it "notifies client when it receives a ping" $ do
    update env ledger (initialState threeParties ledger) (NetworkEvent $ Ping 2) `hasEffect` ClientEffect (PeerConnected 2)

  it "confirms snapshot given it receives AckSn from all parties" $ do
    let s0 = initialState threeParties ledger
        reqSn = NetworkEvent $ ReqSn 1 []
        ackFrom n = NetworkEvent $ AckSn n (Snapshot 1 [] [])
    s1 <- assertNewState $ update env ledger s0 reqSn
    s2 <- assertNewState $ update env ledger s1 (ackFrom 3)
    s3 <- assertNewState $ update env ledger s2 (ackFrom 1)

    getConfirmedSnapshot s3 `shouldBe` Just (Snapshot 0 [] [])

    s4 <- assertNewState $ update env ledger s3 (ackFrom 2)
    getConfirmedSnapshot s4 `shouldBe` Just (Snapshot 1 [] [])

  it "does not confirm snapshots from non-leaders" pending
  it "does not confirm old snapshots" pending

  prop "can handle OnChainEvent in any state" prop_handleOnChainEventInAnyState

genOnChainTx :: Gen (OnChainTx MockTx)
genOnChainTx =
  elements
    [ InitTx mempty
    , CommitTx (ParticipationToken 1 1) [ValidTx 10]
    , CollectComTx []
    , CloseTx (Snapshot 0 mempty mempty) mempty
    , ContestTx
    , FanoutTx [ValidTx 1]
    ]

genHeadStatus :: Gen (HeadStatus MockTx)
genHeadStatus =
  elements
    [ InitState
    , FinalState
    , CollectingState mempty mempty
    , OpenState (SimpleHeadState [] mempty mempty (Snapshot 0 mempty mempty))
    ]

defaultHeadParameters :: HeadParameters
defaultHeadParameters =
  HeadParameters 3600 (Set.singleton 1)

prop_handleOnChainEventInAnyState :: Property
prop_handleOnChainEventInAnyState =
  forAll genHeadStatus $ \st ->
    forAll genOnChainTx $ \tx ->
      collect (tx, st) $
        case update env ledger (HeadState defaultHeadParameters st) (OnChainEvent tx) of
          NewState _ _ -> True
          Wait -> True
          Error _ -> False
 where
  env = Environment 1 NoSnapshots
  ledger = mockLedger

hasEffect :: Tx tx => Outcome tx -> Effect tx -> IO ()
hasEffect (NewState _ effects) effect
  | effect `elem` effects = pure ()
  | otherwise = expectationFailure $ "Missing effect " <> show effect <> " in produced effects:  " <> show effects
hasEffect _ _ = expectationFailure "Unexpected outcome"

initialState ::
  Ord tx =>
  Set Party ->
  Ledger tx ->
  HeadState tx
initialState parties Ledger{initUTxO} =
  let u0 = initUTxO
      snapshot0 = Snapshot 0 u0 mempty
   in HeadState
        { headStatus = OpenState $ SimpleHeadState u0 mempty mempty snapshot0
        , headParameters =
            HeadParameters
              { contestationPeriod = 42
              , parties
              }
        }

getConfirmedTransactions :: HeadState tx -> [tx]
getConfirmedTransactions HeadState{headStatus} = case headStatus of
  OpenState SimpleHeadState{confirmedTxs} -> confirmedTxs
  _ -> []

getConfirmedSnapshot :: HeadState tx -> Maybe (Snapshot tx)
getConfirmedSnapshot HeadState{headStatus} = case headStatus of
  OpenState SimpleHeadState{confirmedSnapshot} -> Just confirmedSnapshot
  _ -> Nothing

assertNewState :: Outcome MockTx -> IO (HeadState MockTx)
assertNewState = \case
  NewState st _ -> pure st
  Error e -> fail (show e)
  Wait -> fail "Found 'Wait'"
