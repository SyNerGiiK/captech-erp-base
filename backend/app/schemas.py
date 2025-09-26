from pydantic import BaseModel, EmailStr, Field
from typing import Optional, List
from datetime import date

# ---- Auth ----
class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"

class UserCreate(BaseModel):
    email: EmailStr
    password: str
    company_name: str

class UserLogin(BaseModel):
    email: EmailStr
    password: str

class MeOut(BaseModel):
    email: EmailStr
    company_id: int

# ---- Clients ----
class ClientBase(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    email: Optional[EmailStr] = None
    phone: Optional[str] = None

class ClientCreate(ClientBase):
    pass

class ClientUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=200)
    email: Optional[EmailStr] = None
    phone: Optional[str] = None

class ClientOut(ClientBase):
    id: int
    class Config:
        from_attributes = True

# ---- Quotes ----
class QuoteBase(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    amount_cents: int = Field(ge=0)
    status: Optional[str] = Field(default="draft")

class QuoteCreate(QuoteBase):
    client_id: int

class QuoteUpdate(BaseModel):
    title: Optional[str] = Field(default=None, min_length=1, max_length=200)
    amount_cents: Optional[int] = Field(default=None, ge=0)
    status: Optional[str] = None
    client_id: Optional[int] = None

class QuoteOut(QuoteBase):
    id: int
    number: str
    client_id: int
    class Config:
        from_attributes = True

# ---- Invoices ----
class InvoiceLineCreate(BaseModel):
    description: str = Field(min_length=1, max_length=300)
    qty: int = Field(ge=1)
    unit_price_cents: int = Field(ge=0)

class InvoiceLineOut(InvoiceLineCreate):
    id: int
    invoice_id: int
    total_cents: int
    class Config:
        from_attributes = True

class InvoiceBase(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    client_id: int
    issued_date: Optional[date] = None
    due_date: Optional[date] = None
    currency: Optional[str] = "EUR"

class InvoiceCreate(InvoiceBase):
    pass

class InvoiceUpdate(BaseModel):
    title: Optional[str] = None
    status: Optional[str] = None
    issued_date: Optional[date] = None
    due_date: Optional[date] = None
    currency: Optional[str] = None

class InvoiceOut(BaseModel):
    id: int
    number: str
    title: str
    status: str
    currency: str
    total_cents: int
    client_id: int
    issued_date: Optional[date] = None
    due_date: Optional[date] = None
    class Config:
        from_attributes = True

# ---- Payments ----
class PaymentCreate(BaseModel):
    amount_cents: int = Field(ge=0)
    method: Optional[str] = None
    paid_at: Optional[date] = None
    note: Optional[str] = None

class PaymentOut(PaymentCreate):
    id: int
    invoice_id: int
    class Config:
        from_attributes = True