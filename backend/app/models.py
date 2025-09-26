from sqlalchemy import Column, Integer, String, ForeignKey, BigInteger, DateTime, UniqueConstraint, Date
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func
from app.db import Base

class Company(Base):
    __tablename__ = "companies"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, unique=True, index=True)

class User(Base):
    __tablename__ = "users"
    id = Column(Integer, primary_key=True, index=True)
    email = Column(String, unique=True, index=True)
    hashed_password = Column(String, nullable=False)
    company_id = Column(Integer, ForeignKey("companies.id"), nullable=False)
    company = relationship("Company")

class Client(Base):
    __tablename__ = "clients"
    id = Column(Integer, primary_key=True, index=True)
    name = Column(String, nullable=False, index=True)
    email = Column(String, nullable=True)
    phone = Column(String, nullable=True)
    company_id = Column(Integer, ForeignKey("companies.id"), nullable=False)
    company = relationship("Company")
    __table_args__ = (
        UniqueConstraint("company_id", "name", name="uq_client_company_name"),
    )

class Quote(Base):
    __tablename__ = "quotes"
    id = Column(Integer, primary_key=True, index=True)
    number = Column(String, unique=True, index=True, nullable=False)
    title = Column(String, nullable=False)
    amount_cents = Column(BigInteger, nullable=False, default=0)
    status = Column(String, nullable=False, default="draft")
    client_id = Column(Integer, ForeignKey("clients.id"), nullable=False)
    company_id = Column(Integer, ForeignKey("companies.id"), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    client = relationship("Client")
    company = relationship("Company")

class Invoice(Base):
    __tablename__ = "invoices"
    id = Column(Integer, primary_key=True, index=True)
    number = Column(String, unique=True, index=True, nullable=False)     # ex: F-2025-0001
    title = Column(String, nullable=False)
    status = Column(String, nullable=False, default="draft")             # draft/sent/paid/cancelled
    currency = Column(String, nullable=False, default="EUR")
    total_cents = Column(BigInteger, nullable=False, default=0)
    issued_date = Column(Date, nullable=True)
    due_date = Column(Date, nullable=True)
    client_id = Column(Integer, ForeignKey("clients.id"), nullable=False)
    company_id = Column(Integer, ForeignKey("companies.id"), nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    client = relationship("Client")
    company = relationship("Company")

class InvoiceLine(Base):
    __tablename__ = "invoice_lines"
    id = Column(Integer, primary_key=True, index=True)
    invoice_id = Column(Integer, ForeignKey("invoices.id", ondelete="CASCADE"), nullable=False)
    description = Column(String, nullable=False)
    qty = Column(Integer, nullable=False, default=1)
    unit_price_cents = Column(BigInteger, nullable=False, default=0)
    total_cents = Column(BigInteger, nullable=False, default=0)

class Payment(Base):
    __tablename__ = "payments"
    id = Column(Integer, primary_key=True, index=True)
    invoice_id = Column(Integer, ForeignKey("invoices.id", ondelete="CASCADE"), nullable=False)
    amount_cents = Column(BigInteger, nullable=False, default=0)
    method = Column(String, nullable=True)           # cash/card/transfer/...
    paid_at = Column(Date, nullable=True)
    note = Column(String, nullable=True)