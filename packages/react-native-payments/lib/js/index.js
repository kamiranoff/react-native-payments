// @flow

import _PaymentRequest from './PaymentRequest';
import _PaymentResponse from './PaymentResponse';
import { PKPaymentButton } from './PKPaymentButton';
import * as CONSTANTS from './constants';

const ApplePayButton = PKPaymentButton;
const PaymentRequest = _PaymentRequest;
const PaymentResponse = _PaymentResponse;

export {
  CONSTANTS,
  ApplePayButton,
  PaymentRequest,
  PaymentResponse,
};
