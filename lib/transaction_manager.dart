import 'dart:async';

import 'package:paystack_flutter/TransactionCallback.dart';
import 'package:paystack_flutter/api/model/transaction_api_response.dart';
import 'package:paystack_flutter/api/request/charge_request_body.dart';
import 'package:paystack_flutter/api/request/validate_request_body.dart';
import 'package:paystack_flutter/api/service/api_service.dart';
import 'package:paystack_flutter/model/card.dart';
import 'package:paystack_flutter/model/charge.dart';
import 'package:paystack_flutter/singletons.dart';
import 'package:paystack_flutter/transaction.dart';
import 'package:flutter/material.dart';
import 'package:paystack_flutter/ui/card_input_ui.dart';

class TransactionManager {
  static bool processing = false;
  final Charge _charge;
  final BuildContext _context;
  final Transaction _transaction = Transaction();
  final TransactionCallback _transactionCallback;
  final CardSingleton _cardSingleton = CardSingleton();
  final PinSingleton _pinSingleton = PinSingleton();
  final OtpSingleton _otpSingleton = OtpSingleton();
  final AuthSingleton _authSingleton = AuthSingleton();
  ChargeRequestBody _chargeRequestBody;
  ValidateRequestBody _validateRequestBody;
  ApiService _apiService;
  var _invalidDataSentRetries = 0;

  _handleServerResponse(Future<TransactionApiResponse> future) {
    future
        .then((TransactionApiResponse apiResponse) =>
        _handleApiResponse(apiResponse))
        .catchError((e) => _notifyProcessingError(e));
  }

  TransactionManager(this._charge, this._transactionCallback, this._context) {
    assert(_context != null, 'context must not be null');
    assert(_charge != null, 'charge must not be null');
    assert(
    _charge.card != null,
    'please add a card to the charge before '
        'calling chargeCard');
    assert(_transactionCallback != null,
    'transactionCallback must not be ' 'null');
  }

  _initiate() {
    if (TransactionManager.processing) {
      throw Exception('A transaction is currently processing, please wait '
          'till it concludes before attempting a new charge.');
    }
    _setProcessingOn();
    _apiService = ApiService();
    _chargeRequestBody = ChargeRequestBody(_charge);
    _validateRequestBody = ValidateRequestBody();
  }

  chargeCard() {
    try {
      if (_charge.card == null || !_charge.card.isValid()) {
        final si = CardSingleton();
        si.card = _charge.card;
        _getCardInfoFrmUI(si);
      } else {
        _initiate();
        _sendChargeToServer();
      }
    } catch (e) {
      print(e.toString());
      _setProcessingOff();
      _transactionCallback.onError(e, _transaction);
    }
  }

  _sendChargeToServer() {
    try {
      _initiateChargeOnServer();
    } catch (e) {
      print(e.toString());
      _notifyProcessingError(e);
    }
  }

  _validate() {
    try {
      _validateChargeOnServer();
    } catch (e) {
      print(e.toString());
      _notifyProcessingError(e);
    }
  }

  _reQuery() {
    try {
      _reQueryChargeOnServer();
    } catch (e) {
      print(e);
      _notifyProcessingError(e);
    }
  }

  _validateChargeOnServer() {
    Map<String, String> params = _validateRequestBody.paramsMap();
    Future<TransactionApiResponse> future = _apiService.validateCharge(params);
    _handleServerResponse(future);
  }

  _reQueryChargeOnServer() {
    Future<TransactionApiResponse> future =
    _apiService.reQueryTransaction(_transaction.id);
    _handleServerResponse(future);
  }

  _initiateChargeOnServer() {
    Future<TransactionApiResponse> future =
    _apiService.charge(_chargeRequestBody.paramsMap());
    _handleServerResponse(future);
  }

  _handleApiResponse(TransactionApiResponse apiResponse) {
    if (apiResponse == null) {
      apiResponse = TransactionApiResponse.unknownServerResponse();
    }

    _transaction.loadFromResponse(apiResponse);

    var status = apiResponse.status.toLowerCase();
    if (status == '1' || status == 'success') {
      _setProcessingOff();
      _transactionCallback.onSuccess(_transaction);
      return;
    }

    if (status == '2') {
      _getPinFrmUI();
      return;
    }

    if (status == '3' && apiResponse.hasValidReferenceAndTrans()) {
      _transactionCallback.beforeValidate(_transaction);
      _validateRequestBody.trans = apiResponse.trans;
      _otpSingleton.otpMessage = apiResponse.message;
      _getOtpFrmUI();
      return;
    }

    if (_transaction.hasStartedOnServer()) {
      if (status == 'requery'.toLowerCase()) {
        _transactionCallback.beforeValidate(_transaction);
        new Timer(const Duration(seconds: 5), () {
          _reQuery();
        });
        return;
      }

      if (apiResponse.hasValidAuth() &&
          apiResponse.auth.toLowerCase() == '3DS'.toLowerCase() &&
          apiResponse.hasValidUrl()) {
        _transactionCallback.beforeValidate(_transaction);
        _authSingleton.url = apiResponse.otpMessage;
        _getAuthFrmUI();
        return;
      }

      if (apiResponse.hasValidAuth() &&
          (apiResponse.auth.toLowerCase() == 'otp'.toLowerCase() ||
              apiResponse.auth.toLowerCase() == 'phone') &&
          apiResponse.hasValidOtpMessage()) {
        _transactionCallback.beforeValidate(_transaction);
        _validateRequestBody.trans = _transaction.id;
        _otpSingleton.otpMessage = apiResponse.otpMessage;
        _getOtpFrmUI();
        return;
      }
    }

    if (status == '0'.toLowerCase() || status == 'error') {
      if (apiResponse.message.toLowerCase() ==
          'Invalid Data Sent'.toLowerCase() && _invalidDataSentRetries < 0) {
        _invalidDataSentRetries++;
        _sendChargeToServer();
        return;
      }

      if (apiResponse.message.toLowerCase() ==
          'Access code has expired'.toLowerCase()) {
        _notifyProcessingError(Exception(apiResponse.message));
        return;
      }

      _notifyProcessingError(Exception(apiResponse.message));
      return;
    }

    _notifyProcessingError(Exception('Unknown server response'));
  }

  _notifyProcessingError(Exception e) {
    _setProcessingOff();
    _transactionCallback.onError(e, _transaction);
  }

  _setProcessingOff() {
    TransactionManager.processing = false;
  }

  _setProcessingOn() {
    TransactionManager.processing = true;
  }

  _getCardInfoFrmUI(CardSingleton si) async {
    PaymentCard result =
    await Navigator.of(_context).push(new MaterialPageRoute<PaymentCard>(
      builder: (BuildContext context) {
        return new CardInputUI(si.card);
      },
    ));

    if (result == null || !result.isValid()) {
      _notifyProcessingError(Exception('Invalid card parameters'));
    } else {
      _charge.card = result;
      chargeCard();
    }
  }

  // TODO: Get PIN, OTP and AUTH from UI
  _getPinFrmUI() {}

  _getOtpFrmUI() {}

  _getAuthFrmUI() {}
}
